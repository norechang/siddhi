/*
 * GpuFilterKernel.h
 *
 *  Created on: Jan 26, 2015
 *      Author: prabodha
 */

#ifndef GPUFILTERKERNEL_H_
#define GPUFILTERKERNEL_H_

#include <stdio.h>
#include "GpuKernel.h"
#include "GpuKernelDataTypes.h"

namespace SiddhiGpu
{

class GpuMetaEvent;
class GpuProcessor;
class GpuProcessorContext;
class GpuIntBuffer;
class GpuStreamEventBuffer;

class GpuFilterKernelStandalone : public GpuKernel
{
public:
	GpuFilterKernelStandalone(GpuProcessor * _pProc, GpuProcessorContext * _pContext, int _iThreadBlockSize, FILE * _fPLog);
	~GpuFilterKernelStandalone();

	bool Initialize(GpuMetaEvent * _pMetaEvent, int _iInputEventBufferSize);
	void Process(int & _iNumEvents, bool _bLast);
	char * GetResultEventBuffer();
	int GetResultEventBufferSize();

private:
	GpuProcessorContext * p_Context;
	GpuKernelFilter * p_DeviceFilter;
	GpuStreamEventBuffer * p_InputEventBuffer;
	GpuIntBuffer * p_ResultEventBuffer;
	bool b_DeviceSet;
};

class GpuFilterKernelFirst : public GpuKernel
{
public:
	GpuFilterKernelFirst(GpuProcessor * _pProc, GpuProcessorContext * _pContext, int _iThreadBlockSize, FILE * _fPLog);
	~GpuFilterKernelFirst();

	bool Initialize(GpuMetaEvent * _pMetaEvent, int _iInputEventBufferSize);
	void Process(int & _iNumEvents, bool _bLast);
	char * GetResultEventBuffer();
	int GetResultEventBufferSize();

private:
	GpuProcessorContext * p_Context;
	GpuKernelFilter * p_DeviceFilter;
	GpuStreamEventBuffer * p_InputEventBuffer;
	GpuIntBuffer * p_MatchedIndexEventBuffer;
	GpuIntBuffer * p_PrefixSumBuffer;
	GpuStreamEventBuffer * p_ResultEventBuffer;
	int i_MatchedEvenBufferIndex;
	int * pi_DeviceMatchedEventCount;
	int * pi_HostMatchedEventCount;
	void * p_TempStorageForPrefixSum;
	size_t i_SizeOfTempStorageForPrefixSum;

	bool b_DeviceSet;
};

}


#endif /* GPUFILTERKERNEL_H_ */