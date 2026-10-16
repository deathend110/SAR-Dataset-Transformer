classdef TestSarWorkflow < matlab.unittest.TestCase
    % 仅运行配置、元数据、数值内核和恢复检查，不启动生产实验。
    methods (TestClassSetup)
        function addRepositoryPath(t)
            repo=string(fileparts(fileparts(mfilename('fullpath'))));
            t.applyFixture(matlab.unittest.fixtures.PathFixture(repo));
            for name = ["workflow", "sampling", "sft", "sarproc", "utils", "compat"]
                t.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(repo,"src",name)));
            end
        end
    end
    methods (Test)
        function entryIsolatesForeignCurrentDirectoryAndRestoresIt(t)
            cfg=range_2dsft_config();
            folder=string(tempname);mkdir(folder);
            cleanup=onCleanup(@()TestSarWorkflow.removeFixture(folder));
            % 模拟旧工程当前目录中的同名函数，保证此例不依赖旧仓库存在。
            file=fullfile(folder,"Range_Compress.m");
            fid=fopen(file,'w','n','UTF-8');
            fprintf(fid,'function varargout=Range_Compress(varargin)\nerror(''foreign:RangeCompress'',''错误的外部函数'');\nend\n');
            fclose(fid);
            previous=pwd;directory_cleanup=onCleanup(@()cd(previous));
            cd(folder);
            t.verifyEqual(string(which('Range_Compress')),file);
            guard=setup_range_2dsft_paths(cfg); %#ok<NASGU>
            t.verifyEqual(string(pwd),cfg.repo_root);
            t.verifyEqual(string(which('Range_Compress')),fullfile(cfg.repo_root,"src","sarproc","Range_Compress.m"));
            clear guard
            t.verifyEqual(string(pwd),folder);
            % 验证公共入口报错时也会恢复外部目录，不滞留在工程目录。
            cfg.stage="invalid_stage";
            t.verifyError(@()run_range_2dsft_workflow(cfg),'sarflow:Stage');
            t.verifyEqual(string(pwd),folder);
            clear directory_cleanup
        end

        function metricMaskUsesProductionCropCoordinates(t)
            cfg=range_2dsft_config();setup_range_2dsft_paths(cfg);S=load(cfg.parameter_file_60);
            [rows,columns]=sar_image_roi_indices(S,600);
            t.verifyEqual(rows,301:900);t.verifyEqual(columns,300:899);
            patch_columns=columns(45:556);t.verifyEqual(patch_columns,344:855);
            mask=sarflow_build_hlh_mask(cfg.sequence);counts=zeros(1,9);
            gt=repmat(uint8(mod(reshape(0:512^2-1,512,512),251)),1,1,9);
            lq=uint8(max(double(gt)-9,0));expected=nan(1,9);
            for k=1:9
                actual=mask.full((k-1)*128+(344:855));counts(k)=sum(~actual);
                if sum(~actual)>=11,expected(k)=ssim(lq(:,~actual,k),gt(:,~actual,k));end
            end
            t.verifyEqual(counts,[0,127,255,383,511,385,257,129,1]);
            out=sarflow_sequence_metrics(lq,gt,cfg,S);
            t.verifyEqual(out.LRegionSSIM,mean(expected,'omitnan'));
            % 将原裁剪算法独立用于实际RC，确认共享坐标没有平移生产图像。
            rng(19);rc=randn(S.nrn,S.nan)+1i*randn(S.nrn,S.nan);
            focused=SAR_Imaging(RCMC(rc,S.lambda,S.fnrn,S.fnan,S.R0,S.C,S.v), ...
                S.lambda,S.Fs,S.R0,S.C,S.v,S.tnan,S.Ta,S.prf);
            old=crop_center(abs(focused(301:900,300:899)),600);
            t.verifyEqual(focus_base_rc(rc,S,600),old);
        end

        function defaultGridAndFractionalSampling(t)
            cfg=range_2dsft_config();setup_range_2dsft_paths(cfg);S=load(cfg.parameter_file_60);
            counts=zeros(3,1);
            for k=1:3
                rows=sarflow_candidate_grid(cfg,S,cfg.search.hl_pairs(k,1),cfg.search.hl_pairs(k,2));
                counts(k)=height(rows);
                t.verifyEqual(numel(unique(rows.ParameterKey)),height(rows));
            end
            t.verifyEqual(counts,[231;165;198]);
            g=resolve_range_grid(1.333,[1200,2224],S);
            t.verifyEqual(g.upsampled_size(1),round(1.333*1200));
            t.verifyEqual(g.Fs_up,S.Fs*g.upsampled_size(1)/1200);
            p=struct("Method","Range_2D_SFT","QHigh",4,"QLow",2, ...
                "STRdB",0,"FrOverBr",0,"FaOverBa",0,"Phi0",0);
            [h,l]=resolve_pair_grids(make_range_sft_pair(p),cfg.sequence,S,cfg.nyquist_margin);
            p.FrOverBr=cfg.nyquist_margin*min(h.Fs_up,l.Fs_up)/(2*S.B);
            t.verifyError(@()resolve_pair_grids(make_range_sft_pair(p),cfg.sequence,S,cfg.nyquist_margin), ...
                'rangeSFT:SFTNyquistViolation');
            a=rows(1,:);fine=sarflow_candidate_grid(cfg,S,a.QHigh,a.QLow,a);
            fine=fine(~ismember(fine.ParameterKey,rows.ParameterKey),:);
            t.verifyEmpty(intersect(rows.ParameterKey,fine.ParameterKey));
        end

        function exactNormalizationAndRCAlignment(t)
            cfg=range_2dsft_config();setup_range_2dsft_paths(cfg);
            rng(42);roi=single(randn(600));stats=struct("VMin",0.1,"VMax",2);
            normalized=minmaxnormalize_image(roi,stats.VMax,stats.VMin);
            old=crop_center(normalized,512);old=uint8(round(max(0,min(1,double(old)))*255));
            t.verifyEqual(sarflow_normalize_frame(roi,stats,512),old);
            mask=sarflow_build_hlh_mask(cfg.sequence);
            t.verifyEqual(mask.boundaries,[856,1368]);
            H=randn(8,2224)+1i*randn(8,2224);L=randn(8,2224)+1i*randn(8,2224);
            [mixed,info]=align_and_mix_rc(H,L,mask.full,64);
            reference=zeros(size(H));reference(:,mask.full)=H(:,mask.full)*info.scale_factor;
            reference(:,~mask.full)=L(:,~mask.full);
            t.verifyEqual(mixed,reference);
            t.verifyEqual(sarflow_frame_columns(cfg.sequence,9),1025:2224);
        end


        function sharedPhysicsKernelMatchesPreviousBranches(t)
            cfg=range_2dsft_config();setup_range_2dsft_paths(cfg);rng(13);
            S=struct("Fs",4,"B",1,"prf",4,"Ba",1,"fc",1e9,"R0",1e6, ...
                "C",3e8,"gama",1e6,"Tp",1);
            s=struct("signal_height",8,"block_width",12);
            parameters=struct("Method","Range_2D_SFT","QHigh",2,"QLow",1, ...
                "STRdB",0,"FrOverBr",0.2,"FaOverBa",0.2,"Phi0",0);
            pair=make_range_sft_pair(parameters);
            [h,l]=resolve_pair_grids(pair,s,S,0.98);
            ch=build_2dsft_carrier(h,pair.H.threshold,S);cl=build_2dsft_carrier(l,pair.L.threshold,S);
            signal=randn(8,12)+1i*randn(8,12);mask=[true(1,4),false(1,4),true(1,4)];
            old_h=generate_range_2dsft_rc(signal,S,pair.H,ch);
            old_l=generate_range_2dsft_rc(signal,S,pair.L,cl);
            [old,info]=align_and_mix_rc(old_h,old_l,mask,2);
            [mixed,actual,aligned,raw_l]=sarflow_mix_sequence_rc(signal,S,pair,mask,2,ch,cl);
            t.verifyEqual(mixed,old);t.verifyEqual(actual,info);
            t.verifyEqual(aligned,old_h*info.scale_factor);t.verifyEqual(raw_l,old_l);
            % 新公共入口在混合模式必须逐元素保留原H/L成像和对齐。
            s=cfg.sequence;s.signal_height=8;
            signal=randn(8,s.block_width)+1i*randn(8,s.block_width);
            [h,l]=resolve_pair_grids(pair,s,S,0.98);
            [ch,cl]=sarflow_build_carriers(pair,h,l,S);mask=sarflow_build_hlh_mask(s);
            [expected,info]=sarflow_mix_sequence_rc(signal,S,pair,mask.full,64,ch,cl);
            [actual,actual_info]=sarflow_sequence_rc(signal,S,pair,s,64,ch,cl);
            t.verifyEqual(actual,expected);t.verifyEqual(actual_info,info);
        end

        function checkpointReadsOldFormatAndChecksOnlyParameters(t)
            folder=string(tempname);mkdir(folder);
            cleanup=onCleanup(@()TestSarWorkflow.removeFixture(folder));
            path=fullfile(folder,"state.mat");parameters=struct("Q",1.75,"STRdB",0);
            state=struct("signature",struct("candidate",parameters,"version","old"),"completed",2);
            sarflow_atomic_save(path,struct("state",state));
            out=sarflow_load_state(path,struct());t.verifyEqual(out.completed,2);
            sarflow_check_parameters(sarflow_state_parameters(out),parameters);
            parameters.Q=2;
            t.verifyError(@()sarflow_check_parameters(sarflow_state_parameters(out),parameters),'sarflow:ParameterMismatch');
        end

        function readOnlyActualCompletedCoarseCheckpoint(t)
            cfg=range_2dsft_config();p=sarflow_paths(cfg);
            path=fullfile(p.checkpoints,"search","coarse_pair_1.mat");
            record_path=fullfile(p.protocol,"run_record.mat");
            t.assumeTrue(isfile(path)&&isfile(record_path),"需要本机原有完整粗搜索检查点。");
            loaded=load(record_path,'record');record=loaded.record;
            for name=string(fieldnames(record.signature.config)).'
                cfg.(name)=record.signature.config.(name);
            end
            cfg.sampling_mode="hlh";
            S=load(cfg.parameter_file_60);
            candidates=sarflow_candidate_grid(cfg,S,cfg.search.hl_pairs(1,1),cfg.search.hl_pairs(1,2));
            state=sarflow_load_state(path,struct());
            % 只有完整旧汇总才调用run_grid，防止本测试意外启动搜索。
            t.assumeTrue(isfield(state,'metrics')&&state.completed==height(candidates));
            session=SarflowSearchSession(cfg);
            actual=sarflow_run_grid(cfg,record,candidates,"coarse_pair_1",session);
            t.verifyEqual(actual,state.metrics);
            t.verifyEqual(session.raw_reads,0);t.verifyEqual(session.rc_calls,0);
            t.verifyEqual(session.carrier_builds,0);
            fprintf('只读旧检查点恢复：%d候选、%d条指标，RC=0、原始回波读取=0。\n',state.completed,height(actual));
        end

        function frozenManifestAndStagePrerequisites(t)
            cfg=range_2dsft_config();setup_range_2dsft_paths(cfg);
            folder=string(tempname);mkdir(folder);
            cleanup=onCleanup(@()TestSarWorkflow.removeFixture(folder));
            cfg.results_root=fullfile(folder,"results");cfg.dataset_root=fullfile(folder,"dataset");cfg.data_root=fullfile(folder,"raw");
            cfg.dataset_names="SmokeScene";mkdir(fullfile(cfg.data_root,cfg.dataset_names));
            % 稀疏MAT仅用于读取变量头和构造清单，避免加载真实大回波。
            raw=sparse(1,1,1i,3598,2234);
            for k=1:7
                save(fullfile(cfg.data_root,cfg.dataset_names,"rstart "+k+".mat"),'raw');
            end
            first=run_range_2dsft_workflow(cfg);second=run_range_2dsft_workflow(cfg);
            t.verifyEqual(first.record,second.record);
            % 缓存容量不参与恢复参数核对，旧配置可继续恢复。
            changed=cfg;changed.search_runtime.cache_gb=0.25;
            resumed=run_range_2dsft_workflow(changed);t.verifyEqual(resumed.record,first.record);
            resumed=run_range_2dsft_workflow(rmfield(cfg,'search_runtime'));
            t.verifyEqual(resumed.record,first.record);
            relocated=cfg;relocated.data_root=fullfile(folder,"relocated");
            copyfile(cfg.data_root,relocated.data_root);
            resumed=run_range_2dsft_workflow(relocated);
            t.verifyEqual(resumed.record.manifest.CStart,first.record.manifest.CStart);
            t.verifyTrue(all(startsWith(resumed.record.manifest.FilePath,relocated.data_root)));
            m=first.record.manifest;t.verifyEqual(sum(m.Role=="search"),5);t.verifyEqual(sum(m.Role=="confirm"),2);
            t.verifyEqual(m.File(m.Role=="confirm"),["rstart 3.mat";"rstart 5.mat"]);
            t.verifyEmpty(intersect(m.File(m.Role=="search"),m.File(m.Role=="confirm")));
            t.verifyTrue(all(m.CStart>=1 & m.CStart+m.BlockWidth-1<=m.RawWidth));
            p=sarflow_paths(cfg);t.verifyFalse(isfile(p.lock));
            cfg.stage="confirm";t.verifyError(@()run_range_2dsft_workflow(cfg),'sarflow:LockMissing');
            locked=table();S=load(cfg.parameter_file_60);
            for k=1:size(cfg.search.hl_pairs,1)
                rows=sarflow_candidate_grid(cfg,S,cfg.search.hl_pairs(k,1),cfg.search.hl_pairs(k,2));
                if isempty(locked),locked=rows(1,:);else,locked=[locked;rows(1,:)];end %#ok<AGROW>
            end
            record=first.record;
            sarflow_atomic_save(p.lock,struct("locked",locked,"record",record,"complete",true, ...
                "metric_protocol","uint8_actual_crop_v2_positive_inf_psnr"));
            for stage=["stats","generate","evaluate"]
                cfg.stage=stage;
                t.verifyError(@()run_range_2dsft_workflow(cfg),'sarflow:Prerequisite');
            end
            cfg.search.STR_grid=0;t.verifyError(@()run_range_2dsft_workflow(cfg),'sarflow:ParameterMismatch');
        end



        function sharedMidpointPercentiles(t)
            folder=string(tempname);mkdir(folder);
            cleanup=onCleanup(@()TestSarWorkflow.removeFixture(folder));
            for k=1:2
                values=single(((k-1)*50:k*50-1).');
                sarflow_atomic_save(fullfile(folder,sprintf('chunk_%06d.mat',k)),struct("values",values));
            end
            stats=sarflow_statistics("calculate_chunk_percentiles",folder,[0.99,99.9], ...
                "JointHL",2,50,0.01,2,true);
            expected=prctile(single((0:99).'),[0.99,99.9],Method="midpoint");
            t.verifyEqual([stats.VMin,stats.VMax],double(expected));
            t.verifyEqual(stats.PixelCount,100);
            t.verifyError(@()sarflow_statistics("calculate_chunk_percentiles",folder,[0.99,99.9], ...
                "JointHL",2,50,0.01,3,true),'scenePercentiles:ChunkCountMismatch');
        end

        function completedEvaluationSkipsPhysicsAndConfirmationRefit(t)
            cfg=range_2dsft_config();setup_range_2dsft_paths(cfg);
            folder=string(tempname);mkdir(folder);
            cleanup=onCleanup(@()TestSarWorkflow.removeFixture(folder));
            cfg.results_root=fullfile(folder,"results");cfg.dataset_root=fullfile(folder,"dataset");cfg.dataset_names="Scene";
            S=load(cfg.parameter_file_60);cfg.search.STR_grid=0;cfg.search.fr_grid=0;cfg.search.fa_grid=0;
            candidate=sarflow_candidate_grid(cfg,S,1.25,1);candidate=candidate(1,:);
            manifest=table(repmat("Scene",7,1),(1:7).',[repmat("search",5,1);repmat("confirm",2,1)], ...
                'VariableNames',["Scene","SequenceID","Role"]);
            record=struct("signature",struct("fixture",1),"manifest",manifest);
            p=sarflow_paths(cfg);directory=fullfile(p.checkpoints,"search","fits",candidate.ParameterKey,"Scene");
            fit=struct("input",struct("VMin",0,"VMax",1),"gt",struct("VMin",0,"VMax",1), ...
                "search_manifest",manifest(1:5,:));
            signature=struct("run",record.signature,"candidate",candidate,"scene","Scene");
            state=struct("signature",signature,"fit",fit);
            sarflow_atomic_save(fullfile(directory,"fit.mat"),struct("state",state));
            for role=["search","confirm"]
                ids=manifest.SequenceID(manifest.Role==role);
                rows=repmat(candidate,numel(ids),1);rows.Scene=repmat("Scene",numel(ids),1);
                rows.SequenceID=ids;rows.Role=repmat(role,numel(ids),1);
                signature=struct("candidate",candidate); % 最早的断点没有指标版本或完整运行记录。
                state=struct("signature",signature,"completed",numel(ids),"metrics",rows);
                sarflow_atomic_save(fullfile(p.checkpoints,role,candidate.ParameterKey,"Scene_metrics.mat"),struct("state",state));
                t.verifyEqual(sarflow_evaluate_candidate(cfg,record,candidate,role),rows);
            end
            % 清单没有FilePath；若错误地重新拟合或成像，上面的调用必然报错。
            saved=load(fullfile(directory,"fit.mat"),'state');t.verifyEqual(saved.state.fit,fit);
        end

        function uint8MetricsAndSceneEqualRanking(t)
            cfg=range_2dsft_config();setup_range_2dsft_paths(cfg);rng(7);
            gt=uint8(randi([0,255],512,512,9));lq=uint8(max(double(gt)-12,0));
            out=sarflow_sequence_metrics(lq,gt,cfg);
            values=zeros(9,1);for k=1:9,values(k)=ssim(lq(:,:,k),gt(:,:,k));end
            t.verifyEqual(out.MeanSSIM,mean(values));
            S=load(cfg.parameter_file_60);cfg.search.STR_grid=0;cfg.search.fr_grid=0;cfg.search.fa_grid=0;
            row=sarflow_candidate_grid(cfg,S,4,2);row=row(1,:);
            rows=[row;row;row];rows.Scene=["A";"A";"B"];
            for name=string(out.Properties.VariableNames),rows.(name)=repmat(out.(name),3,1);end
            rows.MeanSSIM=[0;0;1];ranked=sarflow_rank_candidates(rows);
            t.verifyEqual(ranked.MeanSSIM,0.5);
        end

        function fixedDatasetLayoutWithoutRunID(t)
            cfg=range_2dsft_config();setup_range_2dsft_paths(cfg);
            t.verifyFalse(isfield(cfg,'run_id'));
            paths=sarflow_paths(cfg);
            t.verifyEqual(paths.dataset,fullfile(cfg.repo_root,"dataset_range_2dsft"));
            t.verifyEqual(paths.root,cfg.results_root);
            S=load(cfg.parameter_file_60);
            protocol=sarflow_statistics("build_protocol",cfg,S,10,0.99,99.9,600,64);
            parameters=struct("Method","Range_2D_SFT","QHigh",2.5,"QLow",1.5, ...
                "STRdB",1,"FrOverBr",0.9,"FaOverBa",0.5,"Phi0",0);
            key=sarflow_statistics("make_parameter_key",parameters,protocol);
            t.verifyEqual(key,"range_2d_sft_qh2p5_ql1p5_s1_fr0p9_fa0p5_phi0_lp0p99_hp99p9_roi600_eb64");
            t.verifyEqual(fullfile(paths.dataset,key,"GT"),fullfile(cfg.repo_root,"dataset_range_2dsft",key,"GT"));
        end

        function actualParametersIgnorePathsVersionsAndTimestamps(t)
            cfg=range_2dsft_config();old=cfg;
            old.repo_root="old_repo";old.results_root="old_results";old.data_root="old_data";
            old.version="old";old.parameter_file_60="old_params.mat";
            old.timestamp=123;old.source_manifest=table(1);
            old.stats.memory_gb=0.01;old.search_runtime.cache_gb=0.1;
            sarflow_check_parameters(old,cfg);
            old.sequence.patch_size=511;
            t.verifyError(@()sarflow_check_parameters(old,cfg),'sarflow:ParameterMismatch');
            old.sequence=cfg.sequence;
            a=struct("Fs",60,"R_total",600,"Ba",1,"fnrn",ones(3));
            b=a;b.fnrn=zeros(3);sarflow_check_parameters(a,b);
            b.Ba=2;t.verifyError(@()sarflow_check_parameters(a,b),'sarflow:ParameterMismatch');
            old.search.hl_pairs(1,1)=5;
            t.verifyError(@()sarflow_check_parameters(old,cfg),'sarflow:ParameterMismatch');
        end

        function commitStagesOutsideDatasetAndResumes(t)
            folder=string(tempname);mkdir(folder);
            cleanup=onCleanup(@()TestSarWorkflow.removeFixture(folder));
            cfg=range_2dsft_config();cfg.results_root=fullfile(folder,"results");cfg.dataset_root=fullfile(folder,"dataset");
            paths=sarflow_paths(cfg);image=repmat(uint8(37),4,4,9);
            sarflow_commit_sequence(paths,"key","seq",image,image,struct('q',2));
            t.verifyEqual(sarflow_sequence_output(paths,"key","seq"),"complete");
            t.verifyFalse(isfolder(fullfile(paths.cache,"generation","key","seq")));
            t.verifyEqual(numel(dir(fullfile(paths.dataset,"key","GT","seq","*.png"))),9);
            % 模拟GT已提交、LQ仍在缓存的中断点。
            stage=fullfile(paths.cache,"generation","key","partial");mkdir(fullfile(stage,"LQ"));
            mkdir(fullfile(paths.dataset,"key","GT","partial"));
            for k=0:8
                imwrite(image(:,:,1),fullfile(stage,"LQ",sprintf('%03d.png',k)));
                imwrite(image(:,:,1),fullfile(paths.dataset,"key","GT","partial",sprintf('%03d.png',k)));
            end
            state=struct('parameter_key',"key",'sequence_name',"partial",'phase',"staged");
            sarflow_atomic_save(fullfile(paths.checkpoints,"generation","key","partial.mat"),struct('state',state));
            t.verifyEqual(sarflow_sequence_output(paths,"key","partial"),"complete");
        end

    end
    methods (Static)
        function removeFixture(folder)
            resolved=string(java.io.File(char(folder)).getCanonicalPath());
            root=string(java.io.File(tempdir).getCanonicalPath());
            if resolved==root||~startsWith(lower(resolved),lower(root+string(filesep)))
                error('sarflow:UnsafeFixtureCleanup','拒绝清理临时目录外的路径。');
            end
            if isfolder(resolved),rmdir(resolved,'s');end
        end
    end

end
