/*
 * GpuStreamProcessor.h
 *
 *  Created on: Jan 20, 2015
 *      Author: prabodha
 */

#ifndef GPUSTREAMPROCESSOR_H_
#define GPUSTREAMPROCESSOR_H_

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <string>

namespace SiddhiGpu
{

class GpuMetaEvent;
class GpuProcessor;
class GpuProcessorContext;

class GpuStreamProcessor
{
public:
	GpuStreamProcessor(std::string _sStreamId, int _iStreamIndex, GpuMetaEvent * _pMetaEvent);
	~GpuStreamProcessor();

	bool Initialize(int _iDeviceId, int _iInputEventBufferSize);
	void AddProcessor(GpuProcessor * _pProcessor);
	void Process(int _iNumEvents);

	GpuProcessorContext * GetProcessorContext() { return p_ProcessorContext; }

private:
	std::string s_StreamId;
	int i_StreamIndex;
	GpuMetaEvent * p_MetaEvent;
	GpuProcessor * p_ProcessorChain;
	GpuProcessorContext * p_ProcessorContext;

	FILE * fp_Log;
};

};


#endif /* GPUSTREAMPROCESSOR_H_ */
