/*
 * GpuLengthSlidingWindowProcessor.cpp
 *
 *  Created on: Jan 20, 2015
 *      Author: prabodha
 */


#include "GpuMetaEvent.h"
#include "GpuProcessorContext.h"
#include "GpuLengthSlidingWindowKernel.h"
#include "GpuLengthSlidingWindowProcessor.h"

namespace SiddhiGpu
{

GpuLengthSlidingWindowProcessor::GpuLengthSlidingWindowProcessor(int _iWindowSize) :
	GpuProcessor(GpuProcessor::LENGTH_SLIDING_WINDOW),
	i_WindowSize(_iWindowSize),
	p_Context(NULL),
	p_WindowKernel(NULL),
	p_PrevProcessor(NULL)
{

}

GpuLengthSlidingWindowProcessor::~GpuLengthSlidingWindowProcessor()
{
	if(p_WindowKernel)
	{
		delete p_WindowKernel;
		p_WindowKernel = NULL;
	}

	p_Context = NULL;
	p_PrevProcessor = NULL;
}

GpuProcessor * GpuLengthSlidingWindowProcessor::Clone()
{
	GpuLengthSlidingWindowProcessor * pCloned = new GpuLengthSlidingWindowProcessor(i_WindowSize);

	return pCloned;
}

void GpuLengthSlidingWindowProcessor::Configure(int _iStreamIndex, GpuProcessor * _pPrevProcessor, GpuProcessorContext * _pContext, FILE * _fpLog)
{
	fprintf(fp_Log, "[GpuLengthSlidingWindowProcessor] Configure : StreamIndex=%d PrevProcessor=%p Context=%p \n",
			_iStreamIndex, _pPrevProcessor, _pContext);
	fflush(fp_Log);

	fp_Log = _fpLog;
	p_Context = _pContext;
	p_PrevProcessor = _pPrevProcessor;
}

void GpuLengthSlidingWindowProcessor::Init(int _iStreamIndex, GpuMetaEvent * _pMetaEvent, int _iInputEventBufferSize)
{
	fprintf(fp_Log, "[GpuLengthSlidingWindowProcessor] Init : StreamIndex=%d \n", _iStreamIndex);
	fflush(fp_Log);

	if(p_PrevProcessor)
	{

		switch(p_PrevProcessor->GetType())
		{
		case GpuProcessor::FILTER:
		{
			p_WindowKernel = new GpuLengthSlidingWindowFilterKernel(this, p_Context, i_ThreadBlockSize, i_WindowSize, fp_Log);
			p_WindowKernel->SetInputEventBufferIndex(p_PrevProcessor->GetResultEventBufferIndex());
		}
		break;
		default:
			break;
		}
	}
	else
	{
		p_WindowKernel = new GpuLengthSlidingWindowFirstKernel(this, p_Context, i_ThreadBlockSize, i_WindowSize, fp_Log);
		p_WindowKernel->SetInputEventBufferIndex(0);
	}

	p_WindowKernel->Initialize(_iStreamIndex, _pMetaEvent, _iInputEventBufferSize);

}

int GpuLengthSlidingWindowProcessor::Process(int _iStreamIndex, int _iNumEvents)
{
#ifdef GPU_DEBUG
	fprintf(fp_Log, "[GpuLengthSlidingWindowProcessor] Process : StreamIndex=%d NumEvents=%d \n", _iStreamIndex, _iNumEvents);
	fflush(fp_Log);
#endif

	p_WindowKernel->Process(_iStreamIndex, _iNumEvents, (p_Next == NULL));

	if(p_Next)
	{
		_iNumEvents = p_Next->Process(_iStreamIndex, _iNumEvents);
	}

	return _iNumEvents;
}

void GpuLengthSlidingWindowProcessor::Print(FILE * _fp)
{

}

int GpuLengthSlidingWindowProcessor::GetResultEventBufferIndex()
{
	return p_WindowKernel->GetResultEventBufferIndex();
}

char * GpuLengthSlidingWindowProcessor::GetResultEventBuffer()
{
	return p_WindowKernel->GetResultEventBuffer();
}

int GpuLengthSlidingWindowProcessor::GetResultEventBufferSize()
{
	return p_WindowKernel->GetResultEventBufferSize();
}

}

