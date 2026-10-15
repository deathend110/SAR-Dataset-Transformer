function [first, second] = sarflow_build_carriers(acquisition, grid, other_grid, S60)
%SARFLOW_BUILD_CARRIERS 固定模式仅构造一份候选内载波。
if isfield(acquisition,'single')
    first=build_2dsft_carrier(grid,acquisition.single.threshold,S60);
    second=[];
else
    first=build_2dsft_carrier(grid,acquisition.H.threshold,S60);
    second=build_2dsft_carrier(other_grid,acquisition.L.threshold,S60);
end
end
