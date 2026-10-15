classdef TestSarWorkflow < matlab.unittest.TestCase
    % 仅运行配置、元数据、数值内核和恢复检查，不启动生产实验。
    methods (TestClassSetup)
        function addRepositoryPath(t)
            repo=string(fileparts(fileparts(mfilename('fullpath'))));
            t.applyFixture(matlab.unittest.fixtures.PathFixture(repo));
            for name = ["sarflow", "sampling", "sft", "sarproc"]
                t.applyFixture(matlab.unittest.fixtures.PathFixture(fullfile(repo,name)));
            end
        end
    end
    methods (Test)
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
        end

        function checkpointRejectsMutation(t)
            folder=string(tempname);mkdir(folder);
            cleanup=onCleanup(@()TestSarWorkflow.removeFixture(folder));
            path=fullfile(folder,"state.mat");sig=struct("q",1.75,"seed",42);
            state=struct("signature",sig,"completed",2);
            sarflow_atomic_save(path,struct("state",state));
            out=sarflow_load_state(path,sig,struct());t.verifyEqual(out.completed,2);
            sig.q=2;t.verifyError(@()sarflow_load_state(path,sig,struct()),'sarflow:CheckpointMismatch');
        end

        function frozenManifestAndStagePrerequisites(t)
            cfg=range_2dsft_config();setup_range_2dsft_paths(cfg);
            folder=string(tempname);mkdir(folder);
            cleanup=onCleanup(@()TestSarWorkflow.removeFixture(folder));
            cfg.output_root=fullfile(folder,"outputs");cfg.data_root=fullfile(folder,"raw");
            cfg.dataset_names="SmokeScene";mkdir(fullfile(cfg.data_root,cfg.dataset_names));
            % 稀疏MAT仅用于读取变量头和构造清单，避免加载真实大回波。
            raw=sparse(1,1,1i,3598,2234);
            for k=1:7
                save(fullfile(cfg.data_root,cfg.dataset_names,"rstart "+k+".mat"),'raw');
            end
            first=run_range_2dsft_workflow(cfg);second=run_range_2dsft_workflow(cfg);
            t.verifyEqual(first.record,second.record);
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
            sarflow_atomic_save(p.lock,struct("locked",locked,"record",record,"complete",true));
            for stage=["stats","generate","evaluate"]
                cfg.stage=stage;
                t.verifyError(@()run_range_2dsft_workflow(cfg),'sarflow:Prerequisite');
            end
            cfg.search.STR_grid=0;t.verifyError(@()run_range_2dsft_workflow(cfg),'sarflow:RunMismatch');
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
            cfg.output_root=folder;cfg.dataset_names="Scene";
            S=load(cfg.parameter_file_60);cfg.search.STR_grid=0;cfg.search.fr_grid=0;cfg.search.fa_grid=0;
            candidate=sarflow_candidate_grid(cfg,S,1.25,1);candidate=candidate(1,:);
            manifest=table(repmat("Scene",7,1),(1:7).',[repmat("search",5,1);repmat("confirm",2,1)], ...
                'VariableNames',["Scene","SequenceID","Role"]);
            record=struct("signature",struct("fixture",1),"manifest",manifest);
            p=sarflow_paths(cfg);directory=fullfile(p.search,"candidates",candidate.ParameterKey,"Scene");
            fit=struct("input",struct("VMin",0,"VMax",1),"gt",struct("VMin",0,"VMax",1), ...
                "search_manifest",manifest(1:5,:));
            signature=struct("run",record.signature,"candidate",candidate,"scene","Scene");
            state=struct("signature",signature,"fit",fit);
            sarflow_atomic_save(fullfile(directory,"fit.mat"),struct("state",state));
            for role=["search","confirm"]
                ids=manifest.SequenceID(manifest.Role==role);
                rows=repmat(candidate,numel(ids),1);rows.Scene=repmat("Scene",numel(ids),1);
                rows.SequenceID=ids;rows.Role=repmat(role,numel(ids),1);
                signature=struct("run",record.signature,"candidate",candidate,"role",role,"fit",fit);
                state=struct("signature",signature,"completed",numel(ids),"metrics",rows);
                sarflow_atomic_save(fullfile(directory,role+"_metrics.mat"),struct("state",state));
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
