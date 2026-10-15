classdef TestSarFixedQ < matlab.unittest.TestCase
    % 固定Q单分支数值测试及单场景、单候选的实际轻量闭环。
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
        function fixedGridSchemaAndNyquist(t)
            cfg=range_2dsft_config();cfg.sampling_mode="fixed_q";S=load(cfg.parameter_file_60);
            for q=[2,2.5,3]
                grid=sarflow_candidate_grid(cfg,S,q);
                t.verifyTrue(all(grid.Q==q));
                t.verifyFalse(ismember("QHigh",string(grid.Properties.VariableNames)));
                t.verifyTrue(all(startsWith(grid.ParameterKey,"range_2d_sft_q")));
                t.verifyFalse(any(contains(grid.ParameterKey,"_eb")));
                v=sarflow_statistics("parameter_struct",grid(1,:));
                [g,other]=resolve_pair_grids(make_range_sft_pair(v),cfg.sequence,S,0.98);
                t.verifyEmpty(other);t.verifyEqual(g.upsampled_size(1),round(q*1200));
                v.FrOverBr=0.98*g.Fs_up/(2*S.B);
                t.verifyError(@()resolve_pair_grids(make_range_sft_pair(v),cfg.sequence,S,0.98), ...
                    'rangeSFT:SFTNyquistViolation');
                fine=sarflow_candidate_grid(cfg,S,q,[],grid(1,:));
                fine=fine(~ismember(fine.ParameterKey,grid.ParameterKey),:);
                t.verifyEmpty(intersect(fine.ParameterKey,grid.ParameterKey));
            end
        end

        function singleBranchMatchesDirectPhysics(t)
            rng(73);cfg=range_2dsft_config();cfg.sampling_mode="fixed_q";
            cfg.sequence.signal_height=8;cfg.sequence.block_width=12;
            S=struct("Fs",4,"B",1,"prf",4,"Ba",1,"fc",1e9,"R0",1e6, ...
                "C",3e8,"gama",1e6,"Tp",1);
            signal=randn(8,12)+1i*randn(8,12);
            for q=[2,2.5,3]
                v=struct("Method","Range_2D_SFT","Q",q,"STRdB",0, ...
                    "FrOverBr",0.2,"FaOverBa",0.2,"Phi0",0);
                acq=make_range_sft_pair(v);
                [g,other]=resolve_pair_grids(acq,cfg.sequence,S,0.98);
                [carrier,other_carrier]=sarflow_build_carriers(acq,g,other,S);
                expected=generate_range_2dsft_rc(signal,S,acq.single,carrier);
                [actual,info,first,second]=sarflow_sequence_rc(signal,S,acq,cfg.sequence,64,carrier,[]);
                t.verifyEqual(actual,expected);t.verifyEqual(first,expected);t.verifyEmpty(second);
                t.verifyEmpty(other_carrier);t.verifyTrue(isnan(info.scale_factor));
                stats=struct("VMin",0,"VMax",max(abs(expected),[],'all')+1);
                t.verifyEqual(sarflow_normalize_frame(abs(actual),stats,6), ...
                    sarflow_normalize_frame(abs(expected),stats,6));
            end
        end

        function fixedMetricsAndSceneEqualRanking(t)
            rng(9);cfg=range_2dsft_config();cfg.sampling_mode="fixed_q";
            gt=uint8(randi([0,255],512,512,9));lq=uint8(max(double(gt)-8,0));
            out=sarflow_sequence_metrics(lq,gt,cfg);
            t.verifyTrue(isnan(out.LRegionSSIM));t.verifyTrue(isnan(out.BoundaryGradientExcess));
            cfg.search.STR_grid=[0,1];cfg.search.fr_grid=0;cfg.search.fa_grid=0;
            S=load(cfg.parameter_file_60);grid=sarflow_candidate_grid(cfg,S,2);
            rows=grid([1,1,1,2,2],:);rows.Scene=["A";"A";"B";"A";"B"];
            for name=string(out.Properties.VariableNames),rows.(name)=repmat(out.(name),5,1);end
            rows.MeanSSIM=[0;0;1;0.5;0.5];rows.WorstSSIM=[0.2;0.2;0.2;0.3;0.3];
            ranked=sarflow_rank_candidates(rows);
            t.verifyEqual(ranked.ParameterKey(1),grid.ParameterKey(2));
            t.verifyEqual(ranked.MeanSSIM,[0.5;0.5]);
        end

        function modeIsolationAndValidation(t)
            cfg=range_2dsft_config();p=sarflow_paths(cfg);
            cfg.sampling_mode="fixed_q";f=sarflow_paths(cfg);
            t.verifyEqual(f.dataset,p.dataset);t.verifyEqual(f.evaluation,p.evaluation);
            for name=["protocol","search","confirmation","stats","diagnostics","checkpoints","cache"]
                t.verifyEqual(f.(name),fullfile(p.(name),"fixed_q"));
            end
            t.verifyError(@()sarflow_is_fixed(struct('sampling_mode',"unknown")),'sarflow:SamplingMode');
        end

        function lockRequiresAllRequestedQs(t)
            cfg=range_2dsft_config();cfg.sampling_mode="fixed_q";
            folder=string(tempname);mkdir(folder);
            cleanup=onCleanup(@()TestSarWorkflow.removeFixture(folder));
            cfg.results_root=fullfile(folder,"results");
            cfg.search.STR_grid=0;cfg.search.fr_grid=0;cfg.search.fa_grid=0;
            S=load(cfg.parameter_file_60);locked=table();
            for q=cfg.search.fixed_q_values
                row=sarflow_candidate_grid(cfg,S,q);
                if isempty(locked),locked=row;else,locked=[locked;row];end %#ok<AGROW>
            end
            record=struct("fixture","fixed_q_lock");p=sarflow_paths(cfg);
            sarflow_atomic_save(p.lock,struct("record",record,"locked",locked,"complete",false));
            t.verifyError(@()sarflow_read_lock(cfg,record),'sarflow:LockMismatch');
            sarflow_atomic_save(p.lock,struct("record",record,"locked",locked,"complete",true));
            actual=sarflow_read_lock(cfg,record);t.verifyEqual(actual.Q,[2;2.5;3]);
            locked=locked([2,1,3],:);
            sarflow_atomic_save(p.lock,struct("record",record,"locked",locked,"complete",true));
            t.verifyError(@()sarflow_read_lock(cfg,record),'sarflow:LockedPairs');
        end

        function fixedQEndToEndAndResume(t)
            % 两条轨迹：一条搜索、一条确认；单候选、无新增细候选。
            % 稀疏散射点写为普通single复回波，执行真实成像，产物只写临时目录。
            cfg=range_2dsft_config();cfg.sampling_mode="fixed_q";cfg.stage="all";
            folder=string(tempname);mkdir(folder);
            cleanup=onCleanup(@()TestSarWorkflow.removeFixture(folder));
            cfg.results_root=fullfile(folder,"results");cfg.dataset_root=fullfile(folder,"dataset");
            cfg.data_root=fullfile(folder,"raw");cfg.dataset_names="FixedSmoke";
            mkdir(fullfile(cfg.data_root,cfg.dataset_names));
            cfg.search.fixed_q_values=2;cfg.search.STR_grid=0;
            cfg.search.fr_grid=0.2;cfg.search.fa_grid=0.2;
            cfg.search.fine_STR_offsets=0;cfg.search.fine_frequency_offsets=0;
            cfg.search.search_per_scene=1;cfg.search.confirm_per_scene=1;
            cfg.stats.blocks_per_file=1;
            rng(27);
            for k=1:2
                n=7000;ri=randi(1200,n,1);ci=randi(2224,n,1);
                raw=single(full(sparse(1+3*(ri-1),ci,randn(n,1)+1i*randn(n,1),3598,2224)));
                save(fullfile(cfg.data_root,cfg.dataset_names,"rstart "+k+".mat"),'raw');
            end
            result=run_range_2dsft_workflow(cfg);p=result.paths;
            locked=sarflow_read_lock(cfg,result.record);
            t.verifyEqual(locked.Q,2);t.verifyEqual(height(locked),1);
            x=load(fullfile(p.stats,"fixedsmoke.mat"),'scene_stats');
            entry=x.scene_stats.entries;
            t.verifyEqual(entry.input_stats.Modality,"FixedQ");
            t.verifyEqual(entry.input_stats.ImageCount,18);
            t.verifyEqual(entry.input_stats.PixelCount,18*600^2);
            t.verifyFalse(isfield(entry.audit,'ScaleFactorMean'));
            t.verifyTrue(isfield(entry.effective_sampling,'Single'));
            key=locked.ParameterKey;
            pngs=dir(fullfile(cfg.dataset_root,key,"LQ","*","*.png"));t.verifyEqual(numel(pngs),18);
            fitpath=fullfile(p.checkpoints,"search","fits",key,"FixedSmoke","fit.mat");
            fitfile=dir(fitpath);fit=load(fitpath,'state');
            t.verifyEqual(height(fit.state.fit.search_manifest),1);
            t.verifyTrue(all(fit.state.fit.search_manifest.Role=="search"));
            t.verifyEqual(fit.state.fit.input.ImageCount,9);
            t.verifyTrue(isfile(fullfile(p.evaluation,key,"psnr_ssim_statistics_"+key+".csv")));
            metadata=load(fullfile(cfg.dataset_root,key,"dataset_metadata.mat"),'dataset_metadata');
            t.verifyEqual(metadata.dataset_metadata.signature.sampling_mode,"fixed_q");
            t.verifyFalse(isfield(metadata.dataset_metadata.signature,'energy_buffer'));
            % 用正式统计渲染搜索清单中的同源序列，必须逐像素等于生产PNG。
            S=load(cfg.parameter_file_60);v=sarflow_statistics("parameter_struct",locked);
            acq=make_range_sft_pair(v);[g,other]=resolve_pair_grids(acq,cfg.sequence,S,0.98);
            [ch,cl]=sarflow_build_carriers(acq,g,other,S);
            row=result.record.manifest(result.record.manifest.Role=="search",:);
            signal=sarflow_load_echo_block(row,S,cfg.sequence.block_width);
            [images,targets]=sarflow_render_sequence(signal,S,acq,cfg,entry.input_stats,x.scene_stats.gt, ...
                struct("H",ch,"L",cl),[]);
            name=string(sprintf('fixedsmoke_rstart_%06d_cstart_%09d', ...
                sscanf(char(row.File),'rstart %d.mat'),row.CStart));
            for k=1:9
                t.verifyEqual(imread(fullfile(cfg.dataset_root,key,"LQ",name,sprintf('%03d.png',k-1))),images(:,:,k));
                t.verifyEqual(imread(fullfile(cfg.dataset_root,key,"GT",name,sprintf('%03d.png',k-1))),targets(:,:,k));
            end
            clear ch cl signal images targets
            % 模拟候选汇总尚未提交；序列和拟合断点已经完整保存。
            gridpath=fullfile(p.checkpoints,"search","coarse_pair_1.mat");
            interrupted=load(gridpath,'state');state=interrupted.state;
            state.completed=0;state.metrics=table();sarflow_atomic_save(gridpath,struct("state",state));
            run_range_2dsft_workflow(cfg);
            after=dir(fitpath);t.verifyEqual(after.datenum,fitfile.datenum);
            afterpng=dir(fullfile(cfg.dataset_root,key,"LQ","*","*.png"));
            t.verifyEqual([afterpng.datenum],[pngs.datenum]);
            cfg.search.hl_pairs=[9,8]; % 无关模式的参数不会使固定Q断点失效。
            cfg.stage="preflight";run_range_2dsft_workflow(cfg);
            mixed=cfg;mixed.sampling_mode="hlh";mixed.search.hl_pairs=[3,2];
            mixed_record=run_range_2dsft_workflow(mixed);
            t.verifyEqual(mixed_record.record.manifest,result.record.manifest);
            t.verifyFalse(isfield(mixed_record.record.signature.config,'sampling_mode'));
            t.verifyFalse(isfield(mixed_record.record.signature.config.search,'fixed_q_values'));
            cfg.search.fixed_q_values=2.5;
            t.verifyError(@()run_range_2dsft_workflow(cfg),'sarflow:RunMismatch');
        end
    end
end
