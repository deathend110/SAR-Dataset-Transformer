function ranked = rank_candidates(rows)
%RANK_CANDIDATES 先场景内汇总，再场景等权；稳定参数键用于并列排序。
keys = unique(rows.ParameterKey,'stable');
ranked = table();
names = ["MeanSSIM","LRegionSSIM","WorstSSIM","MeanPSNR", ...
    "GradientRMSE","BrightScattererError","BoundaryGradientExcess","OverlapExcessSSIMLoss"];
for key = keys(:).'
    group = rows(rows.ParameterKey==key,:);
    scenes = unique(group.Scene);
    out = group(1,["Stage","QHigh","QLow","STRdB","FrOverBr","FaOverBa","Phi0","ParameterKey"]);
    out.SceneCount = numel(scenes);
    for name = names
        per_scene = zeros(numel(scenes),1);
        for k=1:numel(scenes)
            per_scene(k) = mean(group.(name)(group.Scene==scenes(k)),'omitnan');
        end
        out.(name) = mean(per_scene,'omitnan');
    end
    if isempty(ranked), ranked=out; else, ranked=[ranked;out]; end %#ok<AGROW>
end
ranked = sortrows(ranked,["MeanSSIM","LRegionSSIM","WorstSSIM","MeanPSNR","ParameterKey"], ...
    ["descend","descend","descend","descend","ascend"]);
ranked.Rank = (1:height(ranked)).';
end
