classdef TestSarFixedQ < matlab.unittest.TestCase
    % 固定Q参数与指标回归，成像测试直接使用本地实际场景的一个回波块。
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
            sarflow_atomic_save(p.lock,struct("record",record,"locked",locked,"complete",false, ...
                "metric_protocol","uint8_actual_crop_v2_positive_inf_psnr"));
            t.verifyError(@()sarflow_read_lock(cfg,record),'sarflow:LockMismatch');
            sarflow_atomic_save(p.lock,struct("record",record,"locked",locked,"complete",true, ...
                "metric_protocol","uint8_actual_crop_v2_positive_inf_psnr"));
            actual=sarflow_read_lock(cfg,record);t.verifyEqual(actual.Q,[2;2.5;3]);
            locked=locked([2,1,3],:);
            sarflow_atomic_save(p.lock,struct("record",record,"locked",locked,"complete",true, ...
                "metric_protocol","uint8_actual_crop_v2_positive_inf_psnr"));
            t.verifyError(@()sarflow_read_lock(cfg,record),'sarflow:ParameterMismatch');
            other=removevars(actual,'Q');other.QHigh=actual.Q;other.QLow=ones(height(actual),1);
            sarflow_atomic_save(p.lock,struct("locked",other,"complete",true));
            t.verifyError(@()sarflow_read_lock(cfg,record),'sarflow:ParameterMismatch');
            % 旧文件没有版本标记也可读取，不因历史标记触发重算。
            sarflow_atomic_save(p.lock,struct("record",record,"locked",actual,"complete",true));
            t.verifyEqual(sarflow_read_lock(cfg,record),actual);
        end

        function realEchoStatisticsGenerationAndMetrics(t)
            % 从一个实际场景截取原始180MHz回波块，不合成稀疏冲激回波。
            % 此例验证真实成像与保存链，不搜索最优参数，也不伪造独立确认集。
            cfg=range_2dsft_config();cfg.sampling_mode="fixed_q";
            scene="SAR_Dataset_Bangkok_1";
            source_file=fullfile(cfg.data_root,scene,"rstart 301.mat");
            t.assumeTrue(isfile(source_file),"需要本地Bangkok场景的rstart 301.mat实际回波。");
            folder=string(tempname);mkdir(folder);
            cleanup=onCleanup(@()TestSarWorkflow.removeFixture(folder));
            cfg.results_root=fullfile(folder,"results");cfg.dataset_root=fullfile(folder,"dataset");
            cfg.data_root=fullfile(folder,"raw");cfg.dataset_names=scene;
            cfg.stats.blocks_per_file=1;
            source_start=1127;
            variables=whos('-file',source_file);echo_variable=variables(1).name;
            loaded=load(source_file,echo_variable);
            raw=loaded.(echo_variable)(:,source_start+(0:cfg.sequence.block_width-1));
            clear loaded
            mkdir(fullfile(cfg.data_root,scene));
            save(fullfile(cfg.data_root,scene,"rstart 301.mat"),'raw','-v7.3');
            clear raw
            cfg.provenance=struct("role","real_echo_smoke_not_parameter_search", ...
                "source_file",source_file,"source_echo_variable",string(echo_variable), ...
                "source_cstart",source_start);
            parameters=table([2;2.5;3],zeros(3,1),ones(3,1),repmat(0.5,3,1),zeros(3,1), ...
                'VariableNames',sarflow_parameter_columns(true));
            run_range_2dsft_stats(cfg,parameters);
            paths=sarflow_paths(cfg);
            x=load(fullfile(paths.stats,"bangkok.mat"),'scene_stats');
            t.verifyEqual(x.scene_stats.gt.ImageCount,9);
            t.verifyEqual(numel(x.scene_stats.entries),3);
            S=load(cfg.parameter_file_60);reference_gt=[];
            for k=1:3
                v=sarflow_statistics("parameter_struct",parameters(k,:));
                output=run_range_2dsft_generate(cfg,v);[~,key]=fileparts(output);key=string(key);
                results=run_range_2dsft_evaluate(cfg,key);
                t.verifyEqual(height(results),1);
                entry=x.scene_stats.entries(string({x.scene_stats.entries.parameter_key})==key);
                t.verifyEqual(entry.input_stats.Modality,"FixedQ");
                t.verifyEqual(entry.input_stats.ImageCount,9);
                t.verifyEqual(entry.input_stats.PixelCount,9*600^2);
                t.verifyTrue(isfield(entry.effective_sampling,'Single'));
                t.verifyFalse(isfield(entry.audit,'ScaleFactorMean'));
                meta=load(fullfile(output,"dataset_metadata.mat"),'dataset_metadata');
                t.verifyEqual(meta.dataset_metadata.signature.workflow.source_file,source_file);
                names=dir(fullfile(output,"GT"));names=names([names.isdir]);
                names=names(~ismember(string({names.name}),[".",".."]));
                t.assertEqual(numel(names),1);sequence_name=string(names.name);
                lq=zeros(512,512,9,'uint8');gt=lq;manual=zeros(1,9);
                for j=1:9
                    file=sprintf('%03d.png',j-1);
                    lq(:,:,j)=imread(fullfile(output,"LQ",sequence_name,file));
                    gt(:,:,j)=imread(fullfile(output,"GT",sequence_name,file));
                    mse=mean((double(lq(:,:,j))-double(gt(:,:,j))).^2,'all');
                    manual(j)=10*log10(255^2/mse);
                end
                out=sarflow_sequence_metrics(lq,gt,cfg,S);
                t.verifyEqual(results.PSNR_Mean,mean(manual),'AbsTol',1e-12);
                t.verifyEqual(results.SSIM_Mean,out.MeanSSIM,'AbsTol',1e-12);
                t.verifyTrue(isfinite(out.MeanSSIM));
                if isempty(reference_gt),reference_gt=gt;else,t.verifyEqual(gt,reference_gt);end
                fprintf('真实回波单块验证 Q=%g：PSNR=%.6f，SSIM=%.6f（指定阈值，非搜索结果）。\n', ...
                    v.Q,results.PSNR_Mean,results.SSIM_Mean);
                if k==1,first_output=output;first_key=key;end
            end
            % 修改临时产物的路径、时间及版本记录，实际参数不变，应继续复用。
            stats_path=fullfile(paths.stats,"bangkok.mat");
            saved_stats=load(stats_path);saved_stats.scene_stats.schema_version="old";
            saved_stats.scene_stats.protocol.parameter_file_60="old_location.mat";
            saved_stats.scene_stats.updated_at="different_time";
            sarflow_atomic_save(stats_path,saved_stats);
            run_range_2dsft_stats(cfg,parameters);
            metadata_path=fullfile(first_output,"dataset_metadata.mat");
            changed_metadata=load(metadata_path);
            changed_metadata.dataset_metadata.signature.schema_version="old";
            changed_metadata.dataset_metadata.signature.script="old_entry.m";
            changed_metadata.dataset_metadata.signature.normalization_sources=struct("StatsFile","gone.mat");
            sarflow_atomic_save(metadata_path,changed_metadata);
            % 完整真实PNG必须复用，不因再次执行而重写。
            before=dir(fullfile(first_output,"LQ","*","*.png"));
            run_range_2dsft_generate(cfg,sarflow_statistics("parameter_struct",parameters(1,:)));
            after=dir(fullfile(first_output,"LQ","*","*.png"));
            t.verifyEqual([after.datenum],[before.datenum]);
            % 用同一实际GT构造合法完美配对，验证+Inf保存及断点恢复。
            for mode=["fixed_q","hlh"]
                check=cfg;check.sampling_mode=mode;
                out=sarflow_sequence_metrics(reference_gt,reference_gt,check,S);
                t.verifyEqual(out.MeanPSNR,Inf);t.verifyEqual(out.MeanSSIM,1);
            end
            identity=cfg;identity.dataset_root=fullfile(folder,"identity_dataset");
            identity.results_root=fullfile(folder,"identity_results");
            destination=fullfile(identity.dataset_root,first_key);mkdir(destination);
            copyfile(fullfile(first_output,"GT"),fullfile(destination,"LQ"));
            copyfile(fullfile(first_output,"GT"),fullfile(destination,"GT"));
            dataset_metadata=struct("signature",struct("role","perfect_pair_metric_regression"));
            save(fullfile(destination,"dataset_metadata.mat"),'dataset_metadata');
            perfect=run_range_2dsft_evaluate(identity,first_key);
            t.verifyEqual(perfect.PSNR_Mean,Inf);t.verifyEqual(perfect.SSIM_Mean,1);
            dataset_metadata.signature=struct("schema_version","old","source_path","changed");
            save(fullfile(destination,"dataset_metadata.mat"),'dataset_metadata');
            resumed=run_range_2dsft_evaluate(identity,first_key);t.verifyEqual(resumed,perfect);
            p=sarflow_paths(identity);
            checkpoint=fullfile(p.checkpoints,"evaluation",first_key,"checkpoint.mat");
            saved=load(checkpoint);signature=saved.parameters; % 重新保存为旧封套，检查旧格式读取。
            for bad=[NaN,-Inf]
                results_table=saved.results_table;results_table.PSNR_Frame000(:)=bad;
                save(checkpoint,'signature','results_table');
                t.verifyError(@()run_range_2dsft_evaluate(identity,first_key), ...
                    'rangeSFTMetrics:CheckpointNonFiniteMetric');
            end
        end
    end
end
