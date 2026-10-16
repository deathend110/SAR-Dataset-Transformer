classdef SarflowSearchSession < handle
    % 搜索/确认会话内共享缓存；不持久化，不影响恢复参数。
    properties (SetAccess=private)
        budget
        bytes = 0
        peak_bytes = 0
        raw_reads = 0
        upsample_calls = 0
        rc_calls = 0
        carrier_builds = 0
        hits = 0
        evictions = 0
    end
    properties (Access=private)
        entries
        clock = 0
    end
    methods
        function obj=SarflowSearchSession(cfg)
            obj.budget=sarflow_search_cache_budget(cfg);
            obj.entries=containers.Map('KeyType','char','ValueType','any');
        end

        function signal=block(obj,row,S60,width)
            key="raw_"+row.SequenceID;
            [signal,found]=obj.get(key);
            if found,return;end
            % 整轨迹只在本次读取期间驻留，缓存只保留裁剪后的60MHz块。
            signal=sarflow_load_echo_block(row,S60,width,false);
            obj.raw_reads=obj.raw_reads+1;
            obj.put(key,signal,"raw");
        end

        function signal_up=upsampled(obj,row,signal,target_rows)
            % 用实际行数而非Q标签区分插值结果，支持小数倍率取整。
            key="up_"+row.SequenceID+"_"+target_rows;
            [signal_up,found]=obj.get(key);
            if found,return;end
            signal_up=upsample_range_fft(signal,target_rows);
            obj.upsample_calls=obj.upsample_calls+1;
            obj.put(key,signal_up,"up");
        end

        function [frames,found]=gt(obj,row,stats)
            [item,found]=obj.get("gt_"+row.SequenceID);
            frames=[];
            if found
                sarflow_check_parameters(item.stats,stats,"GT归一化");
                frames=item.frames;
            end
        end

        function rememberGT(obj,row,stats,frames)
            obj.put("gt_"+row.SequenceID,struct("stats",stats,"frames",frames),"gt");
        end

        function countRC(obj,n),obj.rc_calls=obj.rc_calls+n;end
        function countCarrier(obj),obj.carrier_builds=obj.carrier_builds+1;end

        function out=snapshot(obj)
            out=struct("budget_bytes",obj.budget,"cache_bytes",obj.bytes, ...
                "peak_cache_bytes",obj.peak_bytes,"raw_reads",obj.raw_reads, ...
                "upsample_calls",obj.upsample_calls,"rc_calls",obj.rc_calls, ...
                "carrier_builds",obj.carrier_builds,"hits",obj.hits,"evictions",obj.evictions);
        end
    end
    methods (Access=private)
        function [value,found]=get(obj,key)
            key=char(key);found=isKey(obj.entries,key);value=[];
            if ~found,return;end
            item=obj.entries(key);obj.clock=obj.clock+1;item.tick=obj.clock;
            obj.entries(key)=item;value=item.value;obj.hits=obj.hits+1;
        end

        function put(obj,key,value,kind)
            info=whos('value');n=info.bytes;
            if n>obj.budget,return;end % 超大单项仅供当前计算使用。
            key=char(key);
            if isKey(obj.entries,key),obj.remove(key);end
            while obj.bytes+n>obj.budget
                keys=obj.entries.keys;victim='';oldest=Inf;
                % 上采样先淘汰；插值缓存不能挤走原始块或GT。
                for k=1:numel(keys)
                    item=obj.entries(keys{k});
                    if item.kind=="up"&&item.tick<oldest
                        victim=keys{k};oldest=item.tick;
                    end
                end
                if isempty(victim)&&kind~="up"
                    for k=1:numel(keys)
                        item=obj.entries(keys{k});
                        if item.tick<oldest,victim=keys{k};oldest=item.tick;end
                    end
                end
                if isempty(victim),return;end
                obj.remove(victim);obj.evictions=obj.evictions+1;
            end
            obj.clock=obj.clock+1;
            obj.entries(key)=struct("value",value,"bytes",n,"kind",kind,"tick",obj.clock);
            obj.bytes=obj.bytes+n;obj.peak_bytes=max(obj.peak_bytes,obj.bytes);
        end

        function remove(obj,key)
            item=obj.entries(key);obj.bytes=obj.bytes-item.bytes;
            remove(obj.entries,key);
        end
    end
end
