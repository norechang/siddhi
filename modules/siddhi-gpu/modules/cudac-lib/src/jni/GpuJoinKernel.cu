#ifndef _GPU_JOIN_KERNEL_CU__
#define _GPU_JOIN_KERNEL_CU__

#include <stdio.h>
#include <stdlib.h>
#include "GpuMetaEvent.h"
#include "GpuProcessor.h"
#include "GpuProcessorContext.h"
#include "GpuStreamEventBuffer.h"
#include "GpuRawByteBuffer.h"
#include "GpuIntBuffer.h"
#include "GpuKernelDataTypes.h"
#include "GpuJoinProcessor.h"
#include "GpuJoinKernel.h"
#include "GpuCudaHelper.h"
#include "GpuJoinKernelCore.h"

namespace SiddhiGpu
{

// process batch of events in one stream of join processor
__global__
void ProcessEventsJoin(
		bool                 _bIsLeftTrigger,            // If this is called from Left stream
		char               * _pInputEventBuffer,         // input events buffer
		GpuKernelMetaEvent * _pInputMetaEvent,           // Meta event for input events
		int                  _iInputNumberOfEvents,      // Number of events in input buffer
		char               * _pEventWindowBuffer,        // Event window buffer of this stream
		int                  _iWindowLength,             // Length of current events window
		int                  _iRemainingCount,           // Remaining free slots in Window buffer
		GpuKernelMetaEvent * _pOtherStreamMetaEvent,     // Meta event for other stream
		char               * _pOtherEventWindowBuffer,   // Event window buffer of other stream
		int                  _iOtherWindowLength,        // Length of current events window of other stream
		int                  _iOtherRemainingCount,      // Remaining free slots in Window buffer of other stream
		GpuKernelFilter    * _pOnCompareFilter,          // OnCompare filter buffer - pre-copied at initialization
		int                  _iWithInTime,               // WithIn time in milliseconds
		char               * _pResultsBuffer,            // Resulting events buffer for this stream
		int                  _iEventsPerBlock            // number of events allocated per block
)
{
	// avoid out of bound threads
	if(threadIdx.x >= _iEventsPerBlock || threadIdx.y > 0 || blockIdx.y > 0)
		return;

	if((blockIdx.x == _iInputNumberOfEvents / _iEventsPerBlock) && // last thread block
			(threadIdx.x >= _iInputNumberOfEvents % _iEventsPerBlock)) // extra threads
	{
		return;
	}

	// get assigned event
	int iEventIdx = (blockIdx.x * _iEventsPerBlock) + threadIdx.x;

	// get in event starting position
	char * pInEventBuffer = _pInputEventBuffer + (_pInputMetaEvent->i_SizeOfEventInBytes * iEventIdx);

	// output to results buffer [in event, expired event]
	// my event size (in) + {other stream event size * other window size} + my event size (exp) + {other stream event size * other window size}
	int iOutputSegmentSize = (_pInputMetaEvent->i_SizeOfEventInBytes + (_iOtherWindowLength * _pOtherStreamMetaEvent->i_SizeOfEventInBytes)) * 2;

	char * pResultsInEventBuffer = _pResultsBuffer + (iOutputSegmentSize * iEventIdx);
	char * pResultsExpiredEventBuffer = pResultsInEventBuffer + (iOutputSegmentSize / 2);

	// clear whole result buffer segment for this in event
	memset(pResultsInEventBuffer, 0, iOutputSegmentSize);

	GpuEvent * pExpiredEvent = (GpuEvent *)pResultsExpiredEventBuffer;
	// calculate in/expired event pair for this event

	if(iEventIdx >= _iRemainingCount)
	{
		if(iEventIdx < _iWindowLength)
		{
			// in window buffer
			char * pExpiredOutEventInWindowBuffer = _pEventWindowBuffer + (_pInputMetaEvent->i_SizeOfEventInBytes * (iEventIdx - _iRemainingCount));

			GpuEvent * pWindowEvent = (GpuEvent*) pExpiredOutEventInWindowBuffer;
			if(pWindowEvent->i_Type != GpuEvent::NONE) // if window event is filled
			{
				memcpy(pResultsExpiredEventBuffer, pExpiredOutEventInWindowBuffer, _pInputMetaEvent->i_SizeOfEventInBytes);
				pExpiredEvent->i_Type = GpuEvent::EXPIRED;

			}
			else
			{
				// no expiring event
				pExpiredEvent->i_Type = GpuEvent::NONE;
			}
		}
		else
		{
			// in input event buffer
			char * pExpiredOutEventInInputBuffer = _pInputEventBuffer + (_pInputMetaEvent->i_SizeOfEventInBytes * (iEventIdx - _iWindowLength));

			memcpy(pResultsExpiredEventBuffer, pExpiredOutEventInInputBuffer, _pInputMetaEvent->i_SizeOfEventInBytes);
			pExpiredEvent->i_Type = GpuEvent::EXPIRED;
		}
	}
	else
	{
		// [NULL,inEvent]
		// no expiring event
		pExpiredEvent->i_Type = GpuEvent::NONE;
	}

	// copy in event to result event buffer
	memcpy(pResultsInEventBuffer, pInEventBuffer, _pInputMetaEvent->i_SizeOfEventInBytes);


	// get all matching event for in event from other window buffer and copy them to output event buffer
	GpuEvent * pInEvent = (GpuEvent*) pInEventBuffer;

	// get assigned filter
	GpuKernelFilter mOnCompare = *_pOnCompareFilter;

	// for each events in other window
	int iOtherWindowFillCount  = _iOtherWindowLength - _iOtherRemainingCount;
	for(int i=0; i<iOtherWindowFillCount; ++i)
	{
		// get other window event
		char * pOtherWindowEventBuffer = _pOtherEventWindowBuffer + (_pOtherStreamMetaEvent->i_SizeOfEventInBytes * i);
		GpuEvent * pOtherWindowEvent = (GpuEvent*) pOtherWindowEventBuffer;

		// get buffer position for in event matching results
		char * pResultInMatchingEventBuffer = pResultsInEventBuffer + _pInputMetaEvent->i_SizeOfEventInBytes + (_pOtherStreamMetaEvent->i_SizeOfEventInBytes * i);
		GpuEvent * pResultInMatchingEvent = (GpuEvent*) pResultInMatchingEventBuffer;

		if(pInEvent->i_Sequence > pOtherWindowEvent->i_Sequence && (pInEvent->i_Timestamp - pOtherWindowEvent->i_Timestamp) <= _iWithInTime)
		{
			int iCurrentNodeIdx = 0;
			bool bOnCompareMatched = false;
			if(_bIsLeftTrigger)
			{
				bOnCompareMatched = Evaluate(mOnCompare, _pInputMetaEvent, pInEventBuffer, _pOtherStreamMetaEvent, pOtherWindowEventBuffer, iCurrentNodeIdx);
			}
			else
			{
				bOnCompareMatched = Evaluate(mOnCompare, _pOtherStreamMetaEvent, pOtherWindowEventBuffer, _pInputMetaEvent, pInEventBuffer, iCurrentNodeIdx);
			}

			if(bOnCompareMatched)
			{
				// copy window event to result
				memcpy(pResultInMatchingEventBuffer, pOtherWindowEventBuffer, _pOtherStreamMetaEvent->i_SizeOfEventInBytes);
			}
			else
			{
				// null event
				pResultInMatchingEvent->i_Type = GpuEvent::NONE;
			}
		}
		else
		{
			// cannot continue, last result event for this segment
			pResultInMatchingEvent->i_Type = GpuEvent::RESET;
			break;
		}
	}

	// for each events in other window
	for(int i=0; i<iOtherWindowFillCount; ++i)
	{
		// get other window event
		char * pOtherWindowEventBuffer = _pOtherEventWindowBuffer + (_pOtherStreamMetaEvent->i_SizeOfEventInBytes * i);
		GpuEvent * pOtherWindowEvent = (GpuEvent*) pOtherWindowEventBuffer;

		// get buffer position for expire event matching results
		char * pResultExpireMatchingEventBuffer = pResultsExpiredEventBuffer + _pInputMetaEvent->i_SizeOfEventInBytes + (_pOtherStreamMetaEvent->i_SizeOfEventInBytes * i);
		GpuEvent * pResultExpireMatchingEvent = (GpuEvent*) pResultExpireMatchingEventBuffer;

		if(pExpiredEvent->i_Type == GpuEvent::EXPIRED && pExpiredEvent->i_Sequence < pOtherWindowEvent->i_Sequence &&
				(pOtherWindowEvent->i_Timestamp - pExpiredEvent->i_Timestamp) <= _iWithInTime)
		{
			int iCurrentNodeIdx = 0;
			bool bOnCompareMatched = false;

			if(_bIsLeftTrigger)
			{
				bOnCompareMatched = Evaluate(mOnCompare, _pInputMetaEvent, pInEventBuffer, _pOtherStreamMetaEvent, pOtherWindowEventBuffer, iCurrentNodeIdx);
			}
			else
			{
				bOnCompareMatched = Evaluate(mOnCompare, _pOtherStreamMetaEvent, pOtherWindowEventBuffer, _pInputMetaEvent, pInEventBuffer, iCurrentNodeIdx);
			}

			if(bOnCompareMatched)
			{
				// copy window event to result
				memcpy(pResultExpireMatchingEventBuffer, pOtherWindowEventBuffer, _pOtherStreamMetaEvent->i_SizeOfEventInBytes);
			}
			else
			{
				// null event
				pResultExpireMatchingEvent->i_Type = GpuEvent::NONE;
			}
		}
		else
		{
			// cannot continue, last result event for this segment
			pResultExpireMatchingEvent->i_Type = GpuEvent::RESET;
			break;
		}
	}

}

__global__
void JoinSetWindowState(
		char               * _pInputEventBuffer,     // original input events buffer
		int                  _iNumberOfEvents,       // Number of events in input buffer (matched + not matched)
		char               * _pEventWindowBuffer,    // Event window buffer
		int                  _iWindowLength,         // Length of current events window
		int                  _iRemainingCount,       // Remaining free slots in Window buffer
		int                  _iMaxEventCount,        // used for setting results array
		int                  _iSizeOfEvent,          // Size of an event
		int                  _iEventsPerBlock        // number of events allocated per block
)
{
	// avoid out of bound threads
	if(threadIdx.x >= _iEventsPerBlock || threadIdx.y > 0 || blockIdx.y > 0)
		return;

	if((blockIdx.x == _iNumberOfEvents / _iEventsPerBlock) && // last thread block
			(threadIdx.x >= _iNumberOfEvents % _iEventsPerBlock)) // extra threads
	{
		return;
	}

	// get assigned event
	int iEventIdx = (blockIdx.x * _iEventsPerBlock) + threadIdx.x;

	// get in event starting position
	char * pInEventBuffer = _pInputEventBuffer + (_iSizeOfEvent * iEventIdx);

	if(_iNumberOfEvents < _iWindowLength)
	{
		int iWindowPositionShift = _iWindowLength - _iNumberOfEvents;

		if(_iRemainingCount < _iNumberOfEvents)
		{
			int iExitEventCount = _iNumberOfEvents - _iRemainingCount;

			// calculate start and end window buffer positions
			int iStart = iEventIdx + iWindowPositionShift;
			int iEnd = iStart;
			while(iEnd >= 0)
			{
				char * pDestinationEventBuffer = _pEventWindowBuffer + (_iSizeOfEvent * iEnd);
				GpuEvent * pDestinationEvent = (GpuEvent*) pDestinationEventBuffer;

				if(pDestinationEvent->i_Type != GpuEvent::NONE) // there is an event in destination position
				{
					iEnd -= iExitEventCount;
				}
				else
				{
					break;
				}

			}

			// work back from end while copying events
			while(iEnd < iStart)
			{
				char * pDestinationEventBuffer = _pEventWindowBuffer + (_iSizeOfEvent * iEnd);
				GpuEvent * pDestinationEvent = (GpuEvent*) pDestinationEventBuffer;

				char * pSourceEventBuffer = _pEventWindowBuffer + (_iSizeOfEvent * (iEnd + iExitEventCount));

				memcpy(pDestinationEventBuffer, pSourceEventBuffer, _iSizeOfEvent);
				pDestinationEvent->i_Type = GpuEvent::EXPIRED;

				iEnd += iExitEventCount;
			}

			// iEnd == iStart
			if(iStart >= 0)
			{
				char * pDestinationEventBuffer = _pEventWindowBuffer + (_iSizeOfEvent * iStart);
				GpuEvent * pDestinationEvent = (GpuEvent*) pDestinationEventBuffer;
				memcpy(pDestinationEventBuffer, pInEventBuffer, _iSizeOfEvent);
				pDestinationEvent->i_Type = GpuEvent::EXPIRED;
			}
		}
		else
		{
			// just copy event to window
			iWindowPositionShift -= (_iRemainingCount - _iNumberOfEvents);

			char * pWindowEventBuffer = _pEventWindowBuffer + (_iSizeOfEvent * (iEventIdx + iWindowPositionShift));

			memcpy(pWindowEventBuffer, pInEventBuffer, _iSizeOfEvent);
			GpuEvent * pExpiredEvent = (GpuEvent*) pWindowEventBuffer;
			pExpiredEvent->i_Type = GpuEvent::EXPIRED;
		}
	}
	else
	{
		int iWindowPositionShift = _iNumberOfEvents - _iWindowLength;

		if(iEventIdx >= iWindowPositionShift)
		{
			char * pWindowEventBuffer = _pEventWindowBuffer + (_iSizeOfEvent * (iEventIdx - iWindowPositionShift));

			memcpy(pWindowEventBuffer, pInEventBuffer, _iSizeOfEvent);
			GpuEvent * pExpiredEvent = (GpuEvent*) pWindowEventBuffer;
			pExpiredEvent->i_Type = GpuEvent::EXPIRED;
		}
	}
}


// ======================================================================================================================

GpuJoinKernel::GpuJoinKernel(GpuProcessor * _pProc, GpuProcessorContext * _pLeftContext, GpuProcessorContext * _pRightContext,
		int _iThreadBlockSize, int _iLeftWindowSize, int _iRightWindowSize, FILE * _fpLeftLog, FILE * _fpRightLog) :
	GpuKernel(_pProc, _pLeftContext->GetDeviceId(), _iThreadBlockSize, _fpLeftLog),
	p_LeftContext(_pLeftContext),
	p_RightContext(_pRightContext),
	i_LeftInputBufferIndex(0),
	i_RightInputBufferIndex(0),
	p_LeftInputEventBuffer(NULL),
	p_RightInputEventBuffer(NULL),
	p_LeftWindowEventBuffer(NULL),
	p_RightWindowEventBuffer(NULL),
	p_LeftResultEventBuffer(NULL),
	p_RightResultEventBuffer(NULL),
	p_DeviceOnCompareFilter(NULL),
	i_LeftStreamWindowSize(_iLeftWindowSize),
	i_RightStreamWindowSize(_iRightWindowSize),
	i_LeftRemainingCount(_iLeftWindowSize),
	i_RightRemainingCount(_iRightWindowSize),
	b_LeftDeviceSet(false),
	b_RightDeviceSet(false),
	i_InitializedStreamCount(0),
	fp_LeftLog(_fpLeftLog),
	fp_RightLog(_fpRightLog)
{
	p_JoinProcessor = (GpuJoinProcessor*) _pProc;
	pthread_mutex_init(&mtx_Lock, NULL);
}

GpuJoinKernel::~GpuJoinKernel()
{
	fprintf(fp_LeftLog, "[GpuJoinKernel] destroy\n");
	fflush(fp_LeftLog);
	fprintf(fp_RightLog, "[GpuJoinKernel] destroy\n");
	fflush(fp_RightLog);

	CUDA_CHECK_RETURN(cudaFree(p_DeviceOnCompareFilter));
	p_DeviceOnCompareFilter = NULL;

	pthread_mutex_destroy(&mtx_Lock);
}

bool GpuJoinKernel::Initialize(int _iStreamIndex, GpuMetaEvent * _pMetaEvent, int _iInputEventBufferSize)
{
	fprintf(fp_LeftLog, "[GpuJoinKernel] Initialize : StreamIndex=%d\n", _iStreamIndex);
	fflush(fp_LeftLog);
	fprintf(fp_RightLog, "[GpuJoinKernel] Initialize : StreamIndex=%d\n", _iStreamIndex);
	fflush(fp_RightLog);

	if(_iStreamIndex == 0)
	{
		// set input event buffer
		fprintf(fp_LeftLog, "[GpuJoinKernel] Left InpuEventBufferIndex=%d\n", i_LeftInputBufferIndex);
		fflush(fp_LeftLog);
		p_LeftInputEventBuffer = (GpuStreamEventBuffer*) p_LeftContext->GetEventBuffer(i_LeftInputBufferIndex);
		p_LeftInputEventBuffer->Print();

		// left event window

		p_LeftWindowEventBuffer = new GpuStreamEventBuffer("LeftWindowEventBuffer", p_LeftContext->GetDeviceId(), _pMetaEvent, fp_LeftLog);
		p_LeftWindowEventBuffer->CreateEventBuffer(i_LeftStreamWindowSize);

		fprintf(fp_LeftLog, "[GpuJoinKernel] Created device left window buffer : Length=%d Size=%d bytes\n", i_LeftStreamWindowSize,
				p_LeftWindowEventBuffer->GetEventBufferSizeInBytes());
		fflush(fp_LeftLog);

		fprintf(fp_LeftLog, "[GpuJoinKernel] initialize left window buffer data \n");
		fflush(fp_LeftLog);
		p_LeftWindowEventBuffer->Print();

		p_LeftWindowEventBuffer->ResetHostEventBuffer(0);

		char * pLeftHostWindowBuffer = p_LeftWindowEventBuffer->GetHostEventBuffer();
		char * pCurrentEvent;
		for(int i=0; i<i_LeftStreamWindowSize; ++i)
		{
			pCurrentEvent = pLeftHostWindowBuffer + (_pMetaEvent->i_SizeOfEventInBytes * i);
			GpuEvent * pGpuEvent = (GpuEvent*) pCurrentEvent;
			pGpuEvent->i_Type = GpuEvent::NONE;
		}
		p_LeftWindowEventBuffer->CopyToDevice(false);


		int iLeftResultBufferSizeInBytes = 0;
		if(p_JoinProcessor->GetLeftTrigger())
		{
			iLeftResultBufferSizeInBytes = (p_LeftInputEventBuffer->GetHostMetaEvent()->i_SizeOfEventInBytes +
					(p_RightInputEventBuffer->GetHostMetaEvent()->i_SizeOfEventInBytes * i_RightStreamWindowSize)) * 2
							*  p_LeftInputEventBuffer->GetMaxEventCount();
		}

		p_LeftResultEventBuffer = new GpuRawByteBuffer("JoinLeftResultEventBuffer", p_LeftContext->GetDeviceId(), fp_LeftLog);
		p_LeftResultEventBuffer->CreateEventBuffer(iLeftResultBufferSizeInBytes);

		fprintf(fp_LeftLog, "[GpuJoinKernel] LeftResultEventBuffer created : Size=%d bytes\n", p_LeftResultEventBuffer->GetEventBufferSizeInBytes());
		fflush(fp_LeftLog);
		p_LeftResultEventBuffer->Print();

		i_InitializedStreamCount++;
	}
	else if(_iStreamIndex == 1)
	{
		fprintf(fp_RightLog, "[GpuJoinKernel] Right InpuEventBufferIndex=%d\n", i_RightInputBufferIndex);
		fflush(fp_RightLog);
		p_RightInputEventBuffer = (GpuStreamEventBuffer*) p_RightContext->GetEventBuffer(i_RightInputBufferIndex);
		p_RightInputEventBuffer->Print();

		// right event window

		p_RightWindowEventBuffer = new GpuStreamEventBuffer("RightWindowEventBuffer", p_RightContext->GetDeviceId(), _pMetaEvent, fp_RightLog);
		p_RightWindowEventBuffer->CreateEventBuffer(i_RightStreamWindowSize);

		fprintf(fp_RightLog, "[GpuJoinKernel] Created device right window buffer : Length=%d Size=%d bytes\n", i_RightStreamWindowSize,
				p_RightWindowEventBuffer->GetEventBufferSizeInBytes());
		fflush(fp_RightLog);

		fprintf(fp_RightLog, "[GpuJoinKernel] initialize right window buffer data \n");
		fflush(fp_RightLog);
		p_RightWindowEventBuffer->Print();

		p_RightWindowEventBuffer->ResetHostEventBuffer(0);

		char * pRightHostWindowBuffer = p_RightWindowEventBuffer->GetHostEventBuffer();
		char * pCurrentEvent;
		for(int i=0; i<i_RightStreamWindowSize; ++i)
		{
			pCurrentEvent = pRightHostWindowBuffer + (_pMetaEvent->i_SizeOfEventInBytes * i);
			GpuEvent * pGpuEvent = (GpuEvent*) pCurrentEvent;
			pGpuEvent->i_Type = GpuEvent::NONE;
		}
		p_RightWindowEventBuffer->CopyToDevice(false);

		int iRightResultBufferSizeInBytes = 0;
		if(p_JoinProcessor->GetRightTrigger())
		{
			iRightResultBufferSizeInBytes = (p_RightInputEventBuffer->GetHostMetaEvent()->i_SizeOfEventInBytes +
					(p_LeftInputEventBuffer->GetHostMetaEvent()->i_SizeOfEventInBytes * i_LeftStreamWindowSize)) * 2
							*  p_RightInputEventBuffer->GetMaxEventCount();
		}

		p_RightResultEventBuffer = new GpuRawByteBuffer("JoinRightResultEventBuffer", p_RightContext->GetDeviceId(), fp_RightLog);
		p_RightResultEventBuffer->CreateEventBuffer(iRightResultBufferSizeInBytes);

		fprintf(fp_RightLog, "[GpuJoinKernel] RightResultEventBuffer created : Size=%d bytes\n", p_RightResultEventBuffer->GetEventBufferSizeInBytes());
		fflush(fp_RightLog);
		p_RightResultEventBuffer->Print();

		i_InitializedStreamCount++;
	}

	if(i_InitializedStreamCount == 2)
	{
		fprintf(fp_LeftLog, "[GpuJoinKernel] Copying OnCompare filter to device \n");
		fflush(fp_LeftLog);
		fprintf(fp_RightLog, "[GpuJoinKernel] Copying OnCompare filter to device \n");
		fflush(fp_RightLog);

		CUDA_CHECK_RETURN(cudaMalloc(
				(void**) &p_DeviceOnCompareFilter,
				sizeof(GpuKernelFilter)));

		GpuKernelFilter * apHostFilters = (GpuKernelFilter *) malloc(sizeof(GpuKernelFilter));


		apHostFilters->i_NodeCount = p_JoinProcessor->i_NodeCount;
		apHostFilters->ap_ExecutorNodes = NULL;

		CUDA_CHECK_RETURN(cudaMalloc(
				(void**) &apHostFilters->ap_ExecutorNodes,
				sizeof(ExecutorNode) * p_JoinProcessor->i_NodeCount));

		CUDA_CHECK_RETURN(cudaMemcpy(
				apHostFilters->ap_ExecutorNodes,
				p_JoinProcessor->ap_ExecutorNodes,
				sizeof(ExecutorNode) * p_JoinProcessor->i_NodeCount,
				cudaMemcpyHostToDevice));

		CUDA_CHECK_RETURN(cudaMemcpy(
				p_DeviceOnCompareFilter,
				apHostFilters,
				sizeof(GpuKernelFilter),
				cudaMemcpyHostToDevice));

		CUDA_CHECK_RETURN(cudaPeekAtLastError());
		CUDA_CHECK_RETURN(cudaThreadSynchronize());

		free(apHostFilters);
		apHostFilters = NULL;

		fprintf(fp_LeftLog, "[GpuJoinKernel] Initialization complete\n");
		fflush(fp_LeftLog);
		fprintf(fp_RightLog, "[GpuJoinKernel] Initialization complete\n");
		fflush(fp_RightLog);
	}

	return true;
}

void GpuJoinKernel::Process(int _iStreamIndex, int & _iNumEvents, bool _bLast)
{
	if(_iStreamIndex == 0)
	{
		ProcessLeftStream(_iStreamIndex, _iNumEvents, _bLast);
	}
	else if(_iStreamIndex == 1)
	{
		ProcessRightStream(_iStreamIndex, _iNumEvents, _bLast);
	}
}

void GpuJoinKernel::ProcessLeftStream(int _iStreamIndex, int & _iNumEvents, bool _bLast)
{
#ifdef GPU_DEBUG
	fprintf(fp_LeftLog, "[GpuJoinKernel] ProcessLeftStream : StreamIndex=%d EventCount=%d\n", _iStreamIndex, _iNumEvents);
	fflush(fp_LeftLog);
#endif

	if(!b_LeftDeviceSet)
	{
		GpuCudaHelper::SelectDevice(i_DeviceId, "GpuJoinKernel::Left", fp_LeftLog);
		b_LeftDeviceSet = true;
	}

#ifdef KERNEL_TIME
	sdkStartTimer(&p_StopWatch);
#endif

	// call entry kernel
	int numBlocksX = ceil((float)_iNumEvents / (float)i_ThreadBlockSize);
	int numBlocksY = 1;
	dim3 numBlocks = dim3(numBlocksX, numBlocksY);
	dim3 numThreads = dim3(i_ThreadBlockSize, 1);

	// we need to synchronize processing of JoinKernel as only one batch of events can be there at a time
	pthread_mutex_lock(&mtx_Lock);

#ifdef GPU_DEBUG
	fprintf(fp_LeftLog, "[GpuJoinKernel] ProcessLeftStream : Invoke kernel Blocks(%d,%d) Threads(%d,%d)\n", numBlocksX, numBlocksY, i_ThreadBlockSize, 1);
	fflush(fp_LeftLog);
#endif

//	bool                 _bIsLeftTrigger,            // If this is called from Left stream
//	char               * _pInputEventBuffer,         // input events buffer
//	GpuKernelMetaEvent * _pInputMetaEvent,           // Meta event for input events
//	int                  _iInputNumberOfEvents,      // Number of events in input buffer
//	char               * _pEventWindowBuffer,        // Event window buffer of this stream
//	int                  _iWindowLength,             // Length of current events window
//	int                  _iRemainingCount,           // Remaining free slots in Window buffer
//	GpuKernelMetaEvent * _pOtherStreamMetaEvent,     // Meta event for other stream
//	char               * _pOtherEventWindowBuffer,   // Event window buffer of other stream
//	int                  _iOtherWindowLength,        // Length of current events window of other stream
//	int                  _iOtherRemainingCount,      // Remaining free slots in Window buffer of other stream
//	GpuKernelFilter    * _pOnCompareFilter,          // OnCompare filter buffer - pre-copied at initialization
//	int                  _iWithInTime,               // WithIn time in milliseconds
//	char               * _pResultsBuffer,            // Resulting events buffer for this stream
//	int                  _iEventsPerBlock            // number of events allocated per block

	if(p_JoinProcessor->GetLeftTrigger())
	{

		ProcessEventsJoin<<<numBlocks, numThreads>>>(
				true,
				p_LeftInputEventBuffer->GetDeviceEventBuffer(),
				p_LeftInputEventBuffer->GetDeviceMetaEvent(),
				_iNumEvents,
				p_LeftWindowEventBuffer->GetDeviceEventBuffer(),
				i_LeftStreamWindowSize,
				i_LeftRemainingCount,
				p_RightInputEventBuffer->GetDeviceMetaEvent(),
				p_RightWindowEventBuffer->GetDeviceEventBuffer(),
				i_RightStreamWindowSize,
				i_RightRemainingCount,
				p_DeviceOnCompareFilter,
				p_JoinProcessor->GetWithInTimeMilliSeconds(),
				p_LeftResultEventBuffer->GetDeviceEventBuffer(),
				i_ThreadBlockSize
		);

	}

//	char               * _pInputEventBuffer,     // original input events buffer
//	int                  _iNumberOfEvents,       // Number of events in input buffer (matched + not matched)
//	char               * _pEventWindowBuffer,    // Event window buffer
//	int                  _iWindowLength,         // Length of current events window
//	int                  _iRemainingCount,       // Remaining free slots in Window buffer
//	int                  _iMaxEventCount,        // used for setting results array
//	int                  _iSizeOfEvent,          // Size of an event
//	int                  _iEventsPerBlock        // number of events allocated per block

	JoinSetWindowState<<<numBlocks, numThreads>>>(
			p_LeftInputEventBuffer->GetDeviceEventBuffer(),
			_iNumEvents,
			p_LeftWindowEventBuffer->GetDeviceEventBuffer(),
			i_LeftStreamWindowSize,
			i_LeftRemainingCount,
			p_LeftInputEventBuffer->GetMaxEventCount(),
			p_LeftInputEventBuffer->GetHostMetaEvent()->i_SizeOfEventInBytes,
			i_ThreadBlockSize
	);

	if(_bLast)
	{
		p_LeftResultEventBuffer->CopyToHost(true);
#ifdef GPU_DEBUG
	fprintf(fp_LeftLog, "[GpuJoinKernel] Results copied \n");
	fflush(fp_LeftLog);
#endif
	}

	CUDA_CHECK_RETURN(cudaPeekAtLastError());
	CUDA_CHECK_RETURN(cudaThreadSynchronize());

#ifdef GPU_DEBUG
	fprintf(fp_LeftLog, "[GpuJoinKernel] Kernel complete \n");
	fflush(fp_LeftLog);
#endif



#ifdef KERNEL_TIME
	sdkStopTimer(&p_StopWatch);
	float fElapsed = sdkGetTimerValue(&p_StopWatch);
	fprintf(fp_LeftLog, "[GpuJoinKernel] Stats : Elapsed=%f ms\n", fElapsed);
	fflush(fp_LeftLog);
	lst_ElapsedTimes.push_back(fElapsed);
	sdkResetTimer(&p_StopWatch);
#endif


	if(_iNumEvents > i_LeftRemainingCount)
	{
		i_LeftRemainingCount = 0;
	}
	else
	{
		i_LeftRemainingCount -= _iNumEvents;
	}

	if(!p_JoinProcessor->GetLeftTrigger())
	{
		_iNumEvents = 0;
	}

	pthread_mutex_unlock(&mtx_Lock);
}

void GpuJoinKernel::ProcessRightStream(int _iStreamIndex, int & _iNumEvents, bool _bLast)
{
#ifdef GPU_DEBUG
	fprintf(fp_RightLog, "[GpuJoinKernel] ProcessRightStream : StreamIndex=%d EventCount=%d\n", _iStreamIndex, _iNumEvents);
	fflush(fp_RightLog);
#endif

	if(!b_RightDeviceSet)
	{
		GpuCudaHelper::SelectDevice(i_DeviceId, "GpuJoinKernel::Right", fp_RightLog);
		b_RightDeviceSet = true;
	}

#ifdef KERNEL_TIME
	sdkStartTimer(&p_StopWatch);
#endif

	// call entry kernel
	int numBlocksX = ceil((float)_iNumEvents / (float)i_ThreadBlockSize);
	int numBlocksY = 1;
	dim3 numBlocks = dim3(numBlocksX, numBlocksY);
	dim3 numThreads = dim3(i_ThreadBlockSize, 1);

	// we need to synchronize processing of JoinKernel as only one batch of events can be there at a time
	pthread_mutex_lock(&mtx_Lock);

#ifdef GPU_DEBUG
	fprintf(fp_RightLog, "[GpuJoinKernel] ProcessRightStream : Invoke kernel Blocks(%d,%d) Threads(%d,%d)\n", numBlocksX, numBlocksY, i_ThreadBlockSize, 1);
	fflush(fp_RightLog);
#endif

//	bool                 _bIsLeftTrigger,            // If this is called from Left stream
//	char               * _pInputEventBuffer,         // input events buffer
//	GpuKernelMetaEvent * _pInputMetaEvent,           // Meta event for input events
//	int                  _iInputNumberOfEvents,      // Number of events in input buffer
//	char               * _pEventWindowBuffer,        // Event window buffer of this stream
//	int                  _iWindowLength,             // Length of current events window
//	int                  _iRemainingCount,           // Remaining free slots in Window buffer
//	GpuKernelMetaEvent * _pOtherStreamMetaEvent,     // Meta event for other stream
//	char               * _pOtherEventWindowBuffer,   // Event window buffer of other stream
//	int                  _iOtherWindowLength,        // Length of current events window of other stream
//	int                  _iOtherRemainingCount,      // Remaining free slots in Window buffer of other stream
//	GpuKernelFilter    * _pOnCompareFilter,          // OnCompare filter buffer - pre-copied at initialization
//	int                  _iWithInTime,               // WithIn time in milliseconds
//	char               * _pResultsBuffer,            // Resulting events buffer for this stream
//	int                  _iEventsPerBlock            // number of events allocated per block

	if(p_JoinProcessor->GetRightTrigger())
	{

		ProcessEventsJoin<<<numBlocks, numThreads>>>(
				false,
				p_RightInputEventBuffer->GetDeviceEventBuffer(),
				p_RightInputEventBuffer->GetDeviceMetaEvent(),
				_iNumEvents,
				p_RightWindowEventBuffer->GetDeviceEventBuffer(),
				i_RightStreamWindowSize,
				i_RightRemainingCount,
				p_LeftInputEventBuffer->GetDeviceMetaEvent(),
				p_LeftWindowEventBuffer->GetDeviceEventBuffer(),
				i_LeftStreamWindowSize,
				i_LeftRemainingCount,
				p_DeviceOnCompareFilter,
				p_JoinProcessor->GetWithInTimeMilliSeconds(),
				p_RightResultEventBuffer->GetDeviceEventBuffer(),
				i_ThreadBlockSize
		);

	}

//	char               * _pInputEventBuffer,     // original input events buffer
//	int                  _iNumberOfEvents,       // Number of events in input buffer (matched + not matched)
//	char               * _pEventWindowBuffer,    // Event window buffer
//	int                  _iWindowLength,         // Length of current events window
//	int                  _iRemainingCount,       // Remaining free slots in Window buffer
//	int                  _iMaxEventCount,        // used for setting results array
//	int                  _iSizeOfEvent,          // Size of an event
//	int                  _iEventsPerBlock        // number of events allocated per block

	JoinSetWindowState<<<numBlocks, numThreads>>>(
			p_RightInputEventBuffer->GetDeviceEventBuffer(),
			_iNumEvents,
			p_RightWindowEventBuffer->GetDeviceEventBuffer(),
			i_RightStreamWindowSize,
			i_RightRemainingCount,
			p_RightInputEventBuffer->GetMaxEventCount(),
			p_RightInputEventBuffer->GetHostMetaEvent()->i_SizeOfEventInBytes,
			i_ThreadBlockSize
	);

	if(_bLast)
	{
		p_RightResultEventBuffer->CopyToHost(true);
#ifdef GPU_DEBUG
	fprintf(fp_RightLog, "[GpuJoinKernel] Results copied \n");
	fflush(fp_RightLog);
#endif
	}

	CUDA_CHECK_RETURN(cudaPeekAtLastError());
	CUDA_CHECK_RETURN(cudaThreadSynchronize());

#ifdef GPU_DEBUG
	fprintf(fp_RightLog, "[GpuJoinKernel] Kernel complete \n");
	fflush(fp_RightLog);
#endif



#ifdef KERNEL_TIME
	sdkStopTimer(&p_StopWatch);
	float fElapsed = sdkGetTimerValue(&p_StopWatch);
	fprintf(fp_RightLog, "[GpuJoinKernel] Stats : Elapsed=%f ms\n", fElapsed);
	fflush(fp_RightLog);
	lst_ElapsedTimes.push_back(fElapsed);
	sdkResetTimer(&p_StopWatch);
#endif


	if(_iNumEvents > i_RightRemainingCount)
	{
		i_RightRemainingCount = 0;
	}
	else
	{
		i_RightRemainingCount -= _iNumEvents;
	}

	if(!p_JoinProcessor->GetRightTrigger())
	{
		_iNumEvents = 0;
	}

	pthread_mutex_unlock(&mtx_Lock);
}


char * GpuJoinKernel::GetResultEventBuffer()
{
	return NULL;
}

int GpuJoinKernel::GetResultEventBufferSize()
{
	return 0;
}

char * GpuJoinKernel::GetLeftResultEventBuffer()
{
	return p_LeftResultEventBuffer->GetHostEventBuffer();
}

int GpuJoinKernel::GetLeftResultEventBufferSize()
{
	return p_LeftResultEventBuffer->GetEventBufferSizeInBytes();
}

char * GpuJoinKernel::GetRightResultEventBuffer()
{
	return p_RightResultEventBuffer->GetHostEventBuffer();
}

int GpuJoinKernel::GetRightResultEventBufferSize()
{
	return p_RightResultEventBuffer->GetEventBufferSizeInBytes();
}

}

#endif
