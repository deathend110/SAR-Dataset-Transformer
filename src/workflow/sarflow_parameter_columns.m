function names = sarflow_parameter_columns(fixed)
%SARFLOW_PARAMETER_COLUMNS 固定Q参数表记录真实Q，不伪造H/L倍率。
if fixed,names="Q";else,names=["QHigh","QLow"];end
names=[names,"STRdB","FrOverBr","FaOverBa","Phi0"];
end
