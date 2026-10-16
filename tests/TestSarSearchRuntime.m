classdef TestSarSearchRuntime < matlab.unittest.TestCase
    % 搜索性能改动使用实际场景的5条搜索轨迹作前后对照，不执行完整网格。
    methods (TestClassSetup)
        function paths(t)
            repo=string(fileparts(fileparts(mfilename('fullpath'))));
            t.applyFixture(matlab.unittest.fixtures.PathFixture(repo));
            for name=["workflow","sampling","sft","sarproc","utils","compat"]
                t.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(repo,"src",name)));
            end
        end
    end
    methods (Test)
        function boundedLRUPreservesGTAndUsesActualRows(t)
            cfg=range_2dsft_config();cfg.search_runtime.cache_gb=8192/1024^3;
            session=SarflowSearchSession(cfg);row=table(1,'VariableNames',{'SequenceID'});
            stats=struct("VMin",0,"VMax",1);gt=zeros(16,16,9,'uint8');
            session.rememberGT(row,stats,gt);
            signal=complex(ones(8,12),ones(8,12));
            a=session.upsampled(row,signal,16);b=session.upsampled(row,signal,24);
            t.verifyEqual(a,upsample_range_fft(signal,16));t.verifyEqual(b,upsample_range_fft(signal,24));
            before=session.upsample_calls;session.upsampled(row,signal,24);
            t.verifyEqual(session.upsample_calls,before);
            [actual,found]=session.gt(row,stats);t.verifyTrue(found);t.verifyEqual(actual,gt);
            % 超预算插值项只临时计算，不能挤走GT，也不能突破缓存上限。
            session.upsampled(row,signal,128);session.upsampled(row,signal,128);
            t.verifyEqual(session.upsample_calls,before+2);
            t.verifyLessThanOrEqual(session.peak_bytes,session.budget);
            t.verifyGreaterThan(session.evictions,0);
            [~,found]=session.gt(row,stats);t.verifyTrue(found);
            cfg.search_runtime.cache_gb=0;
            t.verifyError(@()SarflowSearchSession(cfg),'sarflow:SearchCacheBudget');
        end

        function realSceneFiveSequencesMatchReferenceAndResume(t)
            cfg=range_2dsft_config();scene="SAR_Dataset_Bangkok_1";
            t.assumeTrue(isfile(fullfile(cfg.data_root,scene,"rstart 301.mat")), ...
                "需要本地Bangkok实际场景回波。");
            folder=string(tempname);mkdir(folder);
            cleanup=onCleanup(@()TestSarWorkflow.removeFixture(folder));
            cfg.dataset_names=scene;cfg.dataset_root=fullfile(folder,"dataset");
            cfg.search.hl_pairs=[3,2];cfg.search.fixed_q_values=2.5;
            cfg.search.STR_grid=[0,2];cfg.search.fr_grid=0.2;cfg.search.fa_grid=0.2;
            cfg.search.fine_STR_offsets=0;cfg.search.fine_frequency_offsets=0;
            S=load(cfg.parameter_file_60);s=cfg.sequence;first_manifest=table();
            for mode=["hlh","fixed_q"]
                cfg.sampling_mode=mode;cfg.results_root=fullfile(folder,mode,"results");
                record=sarflow_prepare_run(cfg);p=sarflow_paths(cfg);
                rows=record.manifest(record.manifest.Role=="search",:);
                t.assertEqual(height(rows),5);t.assertEqual(numel(unique(rows.FilePath)),5);
                if isempty(first_manifest),first_manifest=record.manifest;
                else,t.verifyEqual(record.manifest,first_manifest);end
                if mode=="fixed_q",grid=sarflow_candidate_grid(cfg,S,2.5);branches=1;
                else,grid=sarflow_candidate_grid(cfg,S,3,2);branches=2;end
                session=SarflowSearchSession(cfg);actual=table();expected=table();
                reference_gt=struct();reference_frames=cell(5,1);old_seconds=zeros(1,2);new_seconds=old_seconds;
                for k=1:2
                    candidate=grid(k,:);timer=tic;
                    [ref,reference_gt,reference_frames,ref_lq]=TestSarSearchRuntime.reference( ...
                        cfg,record,candidate,rows,S,fullfile(folder,mode,"reference",string(k)), ...
                        reference_gt,reference_frames);
                    old_seconds(k)=toc(timer);
                    before=session.snapshot();timer=tic;
                    out=sarflow_evaluate_candidate(cfg,record,candidate,"search",session);
                    new_seconds(k)=toc(timer);after=session.snapshot();
                    t.verifyEqual(out,ref.metrics);
                    t.verifyEqual(after.rc_calls-before.rc_calls,branches*5);
                    t.verifyEqual(after.carrier_builds-before.carrier_builds,1);
                    if k==1
                        t.verifyEqual(after.raw_reads,5);
                        t.verifyEqual(after.upsample_calls,branches*5);
                    else
                        t.verifyEqual(after.raw_reads,before.raw_reads);
                        t.verifyEqual(after.upsample_calls,before.upsample_calls);
                    end
                    fitpath=fullfile(p.checkpoints,"search","fits",candidate.ParameterKey,scene,"fit.mat");
                    saved=load(fitpath,'state');fit=saved.state.fit;
                    t.verifyEqual(fit.input,ref.input_stats);t.verifyEqual(fit.gt,reference_gt);
                    t.verifyEqual(fit.audit,ref.audit);t.verifyEqual(fit.search_manifest,rows);
                    t.verifyEqual(fit.input.PixelCount,branches*5*9*600^2);
                    % 独立重取同一内存ROI入口，逐像素对照旧render产生的uint8九帧。
                    if k==1
                        pair=make_range_sft_pair(sarflow_statistics("parameter_struct",candidate));
                        [h,l]=resolve_pair_grids(pair,s,S,cfg.nyquist_margin);
                        [ch,cl]=sarflow_build_carriers(pair,h,l,S);
                        prepared=sarflow_search_scene(cfg,rows,S,pair,struct("H",ch,"L",cl),session,false);
                        for j=1:5
                            lq=sarflow_normalize_rois(prepared.rois{j},fit.input,s.patch_size);
                            t.verifyTrue(isequal(lq,ref_lq{j}),"新旧uint8帧必须逐像素一致。");
                            gt=sarflow_search_gt_frames(cfg,record,rows(j,:),S,fit.gt,session);
                            t.verifyTrue(isequal(gt,reference_frames{j}));
                        end
                        clear prepared ch cl
                    end
                    if isempty(actual),actual=out;expected=ref.metrics;
                    else,actual=[actual;out];expected=[expected;ref.metrics];end %#ok<AGROW>
                end
                t.verifyEqual(sarflow_rank_candidates(actual),sarflow_rank_candidates(expected));
                t.verifyEmpty(dir(fullfile(p.cache,"**","chunk_*.mat")));
                t.verifyEmpty(dir(fullfile(p.diagnostics,"search","**","*.png")));
                % 场景完整恢复不再成像；旧版部分序列进度重算当前5条，拟合不重做。
                candidate=grid(1,:);metrics_path=fullfile(p.checkpoints,"search",candidate.ParameterKey,scene+"_metrics.mat");
                before=session.snapshot();resumed=sarflow_evaluate_candidate(cfg,record,candidate,"search",session);
                t.verifyEqual(resumed,actual(1:5,:));t.verifyEqual(session.rc_calls,before.rc_calls);
                x=load(metrics_path,'state');x.state.completed=2;x.state.metrics=x.state.metrics(1:2,:);
                sarflow_atomic_save(metrics_path,x);
                old_chunk=fullfile(p.cache,"search","candidates",candidate.ParameterKey,scene,"joint","chunk_000001.mat");
                sarflow_atomic_save(old_chunk,struct("values",single(17)));
                resumed=sarflow_evaluate_candidate(cfg,record,candidate,"search",session);
                t.verifyEqual(resumed,actual(1:5,:));t.verifyEqual(session.rc_calls-before.rc_calls,branches*5);
                untouched=load(old_chunk);t.verifyEqual(untouched.values,single(17));
                % 新候选索引不保存大表；旧完整大表仍可直接复用。
                rebuilt=sarflow_run_grid(cfg,record,grid,"compact",session);t.verifyEqual(rebuilt,actual);
                x=load(fullfile(p.checkpoints,"search","compact.mat"),'state');
                t.verifyFalse(isfield(x.state,'metrics'));t.verifyEqual(x.state.completed,2);
                cfg.search_runtime.cache_gb=0.25;fresh=SarflowSearchSession(cfg);
                rebuilt=sarflow_run_grid(cfg,record,grid,"compact",fresh);
                t.verifyEqual(rebuilt,actual);t.verifyEqual(fresh.raw_reads,0);t.verifyEqual(fresh.rc_calls,0);
                x.state.metrics=actual;sarflow_atomic_save(fullfile(p.checkpoints,"search","old_complete.mat"),x);
                t.verifyEqual(sarflow_run_grid(cfg,record,grid,"old_complete",fresh),actual);
                t.verifyEqual(fresh.rc_calls,0);
                cfg.search_runtime.cache_gb=8;
                ranked=sarflow_rank_candidates(actual);before=session.snapshot();
                sarflow_locked_contacts(cfg,record,ranked(1,:),session);
                t.verifyEqual(session.rc_calls-before.rc_calls,branches);
                images=dir(fullfile(p.diagnostics,"search","**","*.png"));
                t.assertEqual(numel(images),1);
                contact=imread(fullfile(images(1).folder,images(1).name));
                t.verifyEqual(size(contact),[1024,4608]);
                sarflow_locked_contacts(cfg,record,ranked(1,:),session);
                t.verifyEqual(session.rc_calls-before.rc_calls,branches);
                % 独立确认只读搜索拟合，另载2条真实轨迹，不参与GT/输入拟合。
                fitpath=fullfile(p.checkpoints,"search","fits",candidate.ParameterKey,scene,"fit.mat");
                old_fit=load(fitpath);before=session.snapshot();
                confirmation=sarflow_evaluate_candidate(cfg,record,candidate,"confirm",session);
                t.verifyEqual(height(confirmation),2);t.verifyEqual(session.raw_reads-before.raw_reads,2);
                t.verifyEqual(session.rc_calls-before.rc_calls,branches*2);
                t.verifyEqual(load(fitpath),old_fit);
                gt_state=load(fullfile(p.checkpoints,"search","gt",scene,"state.mat"));
                t.verifyEqual(gt_state.state.stats.ImageCount,45);
                % 旧版GT uint8文件在新会话直接读取，完整GT拟合也直接读取。
                confirm_rows=record.manifest(record.manifest.Role=="confirm",:);row=confirm_rows(1,:);
                frames=sarflow_search_gt_frames(cfg,record,row,S,old_fit.state.fit.gt,session);
                sig=struct("run",record.signature,"row",row,"stats",old_fit.state.fit.gt);
                state=struct("signature",sig,"frames",frames);
                sarflow_atomic_save(fullfile(p.cache,"gt_frames",sprintf('sequence_%06d.mat',row.SequenceID)),struct("state",state));
                t.verifyEqual(sarflow_search_gt_frames(cfg,record,row,S,old_fit.state.fit.gt,fresh),frames);
                t.verifyEqual(sarflow_fit_gt(cfg,record,scene,fresh),old_fit.state.fit.gt);
                t.verifyEqual(fresh.raw_reads,0);
                footprint=session.snapshot();
                fprintf('搜索加速真实场景 %s：参考两候选 %.3fs/%.3fs，新冷/热 %.3fs/%.3fs，总加速 %.3fx，缓存 %.3fGiB，峰值 %.3fGiB。\n', ...
                    mode,old_seconds,new_seconds,sum(old_seconds)/sum(new_seconds), ...
                    footprint.cache_bytes/1024^3,footprint.peak_cache_bytes/1024^3);
                clear session fresh reference_frames ref_lq
            end
        end
    end
    methods (Static,Access=private)
        function [ref,gt_stats,gt_frames,lq_frames]=reference(cfg,record,candidate,rows,S,directory,gt_stats,gt_frames)
            % 保留的正式chunk内核+原逐序列render，作为优化前数值与耗时基线。
            p=sarflow_statistics("parameter_struct",candidate);pair=make_range_sft_pair(p);
            [h,l]=resolve_pair_grids(pair,cfg.sequence,S,cfg.nyquist_margin);
            [ch,cl]=sarflow_build_carriers(pair,h,l,S);
            ref=sarflow_statistics("process_scene_parameter",cfg,S,rows,pair,p, ...
                record.signature.protocol,directory,false,ch,cl,cfg.stats.memory_gb,true,fullfile(directory,"checkpoint"));
            if isempty(fieldnames(gt_stats))
                for j=1:height(rows)
                    signal=sarflow_load_echo_block(rows(j,:),S,cfg.sequence.block_width);
                    values=zeros(cfg.sequence.roi_size^2*9,1,'single');
                    for f=1:9
                        roi=generate_gt_image(signal(:,sarflow_frame_columns(cfg.sequence,f)),S,cfg.sequence.roi_size);
                        values((f-1)*numel(roi)+(1:numel(roi)))=single(roi(:));
                    end
                    sarflow_atomic_save(fullfile(directory,"gt",sprintf('chunk_%06d.mat',j)),struct("values",values));
                end
                gt_stats=sarflow_statistics("calculate_chunk_percentiles",fullfile(directory,"gt"), ...
                    [cfg.low_percentile,cfg.high_percentile],"GT",height(rows)*9,600^2,8,height(rows),true);
            end
            ref.metrics=table();lq_frames=cell(height(rows),1);
            for j=1:height(rows)
                signal=sarflow_load_echo_block(rows(j,:),S,cfg.sequence.block_width);
                [lq,gt,gt_frames{j}]=sarflow_render_sequence(signal,S,pair,cfg, ...
                    ref.input_stats,gt_stats,struct("H",ch,"L",cl),gt_frames{j});
                lq_frames{j}=lq;row=candidate;row.Scene=rows.Scene(j);row.SequenceID=rows.SequenceID(j);row.Role="search";
                row=[row,sarflow_sequence_metrics(lq,gt,cfg,S)]; %#ok<AGROW>
                if isempty(ref.metrics),ref.metrics=row;else,ref.metrics=[ref.metrics;row];end
                % 旧流程逐序列写增长表，基线包含这部分小型磁盘开销。
                sarflow_atomic_save(fullfile(directory,"metrics.mat"),struct("metrics",ref.metrics));
            end
        end
    end
end
