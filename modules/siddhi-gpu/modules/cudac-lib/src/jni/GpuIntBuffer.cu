#ifndef _GPU_INT_EVENT_BUFFER_CU__
#define _GPU_INT_EVENT_BUFFER_CU__

#include <stdio.h>
#include <stdlib.h>
#include "GpuKernelDataTypes.h"
#include "GpuMetaEvent.h"
#include "GpuCudaHelper.h"
#include "GpuIntBuffer.h"


namespace SiddhiGpu
{

GpuIntBuffer::GpuIntBuffer(int _iDeviceId, GpuMetaEvent * _pMetaEvent, FILE * _fpLog) :
	GpuEventBuffer(_iDeviceId, _pMetaEvent, _fpLog),
	p_HostEventBuffer(NULL),
	p_UnalignedBuffer(NULL),
	p_DeviceEventBuffer(NULL),
	i_EventBufferSizeInBytes(0),
	i_EventCount(0)
{
	fprintf(fp_Log, "[GpuIntBuffer] Created with device id : %d", i_DeviceId);
	fflush(fp_Log);
}

GpuIntBuffer::~GpuIntBuffer()
{
	fprintf(fp_Log, "[GpuIntBuffer] destroy\n");
	fflush(fp_Log);

	GpuCudaHelper::FreeHostMemory(true, &p_UnalignedBuffer, &p_HostEventBuffer, i_EventBufferSizeInBytes, fp_Log);

	if(p_DeviceMetaEvent)
	{
		CUDA_CHECK_RETURN(cudaFree(p_DeviceMetaEvent));
	}
}

void GpuIntBuffer::SetEventBuffer(int * _pBuffer, int _iBufferSizeInBytes, int _iEventCount)
{
	p_HostEventBuffer = _pBuffer;
	i_EventBufferSizeInBytes = _iBufferSizeInBytes;
	i_EventCount = _iEventCount;

	fprintf(fp_Log, "[GpuIntBuffer] Set ByteBuffer [Ptr=%p Count=%d Size=%d bytes]\n", p_HostEventBuffer, i_EventCount, i_EventBufferSizeInBytes);
	fflush(fp_Log);
}

int * GpuIntBuffer::CreateEventBuffer(int _iEventCount)
{
	i_EventCount = _iEventCount;
	i_EventBufferSizeInBytes = _iEventCount * p_HostMetaEvent->i_SizeOfEventInBytes;
	fprintf(fp_Log, "[GpuIntBuffer] Allocating ByteBuffer for %d events : %d bytes \n", _iEventCount, (int)(sizeof(char) * i_EventBufferSizeInBytes));
	fflush(fp_Log);

	GpuCudaHelper::AllocateHostMemory(true, &p_UnalignedBuffer, &p_HostEventBuffer, i_EventBufferSizeInBytes, fp_Log);

	CUDA_CHECK_RETURN(cudaMalloc((void**) &p_DeviceEventBuffer, i_EventBufferSizeInBytes));

	fprintf(fp_Log, "[GpuIntBuffer] Host ByteBuffer [Ptr=%p Size=%d]\n", p_HostEventBuffer, i_EventBufferSizeInBytes);
	fprintf(fp_Log, "[GpuIntBuffer] Device ByteBuffer [Ptr=%p] \n", p_DeviceEventBuffer);
	fflush(fp_Log);

	int GpuMetaEventSize = sizeof(GpuKernelMetaEvent) + sizeof(GpuKernelMetaAttribute) * p_HostMetaEvent->i_AttributeCount;

	CUDA_CHECK_RETURN(cudaMalloc((void**) &p_DeviceMetaEvent, GpuMetaEventSize));

	GpuKernelMetaEvent * pHostMetaEvent = (GpuKernelMetaEvent*) malloc(GpuMetaEventSize);

	pHostMetaEvent->i_StreamIndex = p_HostMetaEvent->i_StreamIndex;
	pHostMetaEvent->i_AttributeCount = p_HostMetaEvent->i_AttributeCount;
	pHostMetaEvent->i_SizeOfEventInBytes = p_HostMetaEvent->i_SizeOfEventInBytes;

	for(int i=0; i<p_HostMetaEvent->i_AttributeCount; ++i)
	{
		pHostMetaEvent->p_Attributes[i].i_Type = p_HostMetaEvent->p_Attributes[i].i_Type;
		pHostMetaEvent->p_Attributes[i].i_Position = p_HostMetaEvent->p_Attributes[i].i_Position;
		pHostMetaEvent->p_Attributes[i].i_Length = p_HostMetaEvent->p_Attributes[i].i_Length;
	}

	CUDA_CHECK_RETURN(cudaMemcpy(
		p_DeviceMetaEvent,
		pHostMetaEvent,
		GpuMetaEventSize,
		cudaMemcpyHostToDevice));

	CUDA_CHECK_RETURN(cudaPeekAtLastError());
	CUDA_CHECK_RETURN(cudaThreadSynchronize());

	free(pHostMetaEvent);
	pHostMetaEvent = NULL;

	return p_HostEventBuffer;
}

void GpuIntBuffer::CopyToDevice(bool _bAsync)
{
	fprintf(fp_Log, "[GpuIntBuffer] CopyToDevice : Async=%d\n", _bAsync);

	if(_bAsync)
	{
		CUDA_CHECK_RETURN(cudaMemcpyAsync(p_DeviceEventBuffer, p_HostEventBuffer, i_EventBufferSizeInBytes, cudaMemcpyHostToDevice));
	}
	else
	{
		CUDA_CHECK_RETURN(cudaMemcpy(p_DeviceEventBuffer, p_HostEventBuffer, i_EventBufferSizeInBytes, cudaMemcpyHostToDevice));
	}
}

void GpuIntBuffer::CopyToHost(bool _bAsync)
{
	fprintf(fp_Log, "[GpuIntBuffer] CopyToHost : Async=%d\n", _bAsync);

	if(_bAsync)
	{
		CUDA_CHECK_RETURN(cudaMemcpyAsync(p_HostEventBuffer, p_DeviceEventBuffer, i_EventBufferSizeInBytes, cudaMemcpyDeviceToHost));
	}
	else
	{
		CUDA_CHECK_RETURN(cudaMemcpy(p_HostEventBuffer, p_DeviceEventBuffer, i_EventBufferSizeInBytes, cudaMemcpyDeviceToHost));
	}
}


#endif
