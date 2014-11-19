/*
 * GpuEventConsumer.cpp
 *
 *  Created on: Oct 23, 2014
 *      Author: prabodha
 */

#include "GpuEventConsumer.h"
#include <stdlib.h>
#include <vector>

namespace SiddhiGpu
{


GpuEventConsumer::GpuEventConsumer(KernelType _eKernelType, int _iMaxBufferSize, int _iEventsPerBlock) :
	i_MaxBufferSize(_iMaxBufferSize)
{
	fp_Log = fopen("logs/GpuEventConsumer.log", "w");

	vec_Result.reserve(i_MaxBufferSize);

	switch(_eKernelType)
	{
		case SingleFilterKernel:
		{
			fprintf(fp_Log, "EventConsumerGpu created for SingleFilterKernel\n");
			p_CudaKernel = new CudaSingleFilterKernel(i_MaxBufferSize, _iEventsPerBlock, this, fp_Log);
		}
		break;
		case MultiFilterKernel:
		{
			fprintf(fp_Log, "EventConsumerGpu created for MultiFilterKernel\n");
			p_CudaKernel = new CudaFilterKernel(i_MaxBufferSize, this, fp_Log);
		}
		break;
		default:
			p_CudaKernel = NULL;
			break;
	}


	fprintf(fp_Log, "EventConsumer : MaxBufferSize=[%d events]\n", i_MaxBufferSize);
}

GpuEventConsumer::~GpuEventConsumer()
{
	delete p_CudaKernel;

	fflush(fp_Log);
	fclose(fp_Log);
}


void GpuEventConsumer::Initialize()
{
	p_CudaKernel->Initialize();
}

void GpuEventConsumer::OnEvents(CudaEvent ** _apEvents, int _iEventCount)
{
	fprintf(fp_Log, "OnEvents : Event batch size [%d] \n", _iEventCount);
	vec_Result.clear();
	p_CudaKernel->AddAndProcessEvents(_apEvents, _iEventCount);

	// release internally allocated string memory
	for(int i=0; i<_iEventCount; ++i)
	{
		if(_apEvents[i])
		{
			_apEvents[i]->Destroy();
		}
	}
}

void GpuEventConsumer::AddFilter(Filter * _pFilter)
{
	_pFilter->Print(fp_Log);

	FiltersById::iterator ite = map_FiltersById.find(_pFilter->i_FilterId);
	if(ite == map_FiltersById.end())
	{
		map_FiltersById.insert(std::make_pair(_pFilter->i_FilterId, _pFilter));
	}
}

void GpuEventConsumer::ConfigureFilters()
{
	fprintf(fp_Log, "ConfigureFilters : FilterCount=%d\n", (int)map_FiltersById.size());

	FiltersById::iterator ite = map_FiltersById.begin();
	while(ite != map_FiltersById.end())
	{
		Filter * pFilter = ite->second;
		p_CudaKernel->AddFilterToDevice(pFilter);

		++ite;
	}
	p_CudaKernel->CopyFiltersToDevice();
}

void GpuEventConsumer::OnEventMatch(CudaEvent * _pEvent, int _iFilterId)
{
//	fprintf(fp_Log, "OnEventMatch : EventId=%" PRIu64 " FilterId=%d \n", _pEvent->ui_Timestamp, _iFilterId);
}

void GpuEventConsumer::OnCudaEventMatch(int _iEventPos, int _iFilterId)
{
//	OnEventMatch(ap_Events[_iEventPos], _iFilterId);
//	fprintf(fp_Log, "OnEventMatch : EventPos=%d FilterId=%d \n", _iEventPos, _iFilterId);
	vec_Result.push_back(_iEventPos);
}

void GpuEventConsumer::PrintAverageStats()
{
	float f = p_CudaKernel->GetElapsedTimeAverage();
	float fpe = f / i_MaxBufferSize;
//	printf("Average Elapsed Time (Event Batch Size : %d - %f ms) : %f ms per event\n", i_MaxBufferSize, f, fpe);
	fprintf(fp_Log, "GPU Average Elapsed Time (Event Batch Size : %d - %f ms) : %f ms per event\n", i_MaxBufferSize, f, fpe);
	fflush(fp_Log);
}

std::vector<int> GpuEventConsumer::GetMatchingEvents()
{
	return vec_Result;
}

};
