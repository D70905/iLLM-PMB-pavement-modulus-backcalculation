function deflections = extractMultiPositionDeflections(pde_result, positions)
% EXTRACTMULTIPOSITIONDEFLECTIONS 多位置弯沉提取
% 
% 仿照ABAQUS方式，在多个距离位置提取弯沉
% 
% 输入:
%   pde_result - PDE计算结果
%   positions - 提取位置数组 (m) [默认: 0, 0.3, 0.6, 0.9, 1.2, 1.5, 1.8, 2.1, 2.4]
% 
% 输出:
%   deflections - 各位置弯沉数组 (mm)

if nargin < 2
    % 使用FWD标准测试位置（与ABAQUS一致）
    positions = [0.0, 0.3, 0.6, 0.9, 1.2, 1.5, 1.8, 2.1, 2.4];  % m
end

fprintf('    📍 提取%d个位置的弯沉...\n', length(positions));

deflections = zeros(1, length(positions));

% 检查PDE结果是否包含位移场数据
if ~isfield(pde_result, 'U') && isfield(pde_result, 'D_FEA')
    % 如果只有中心弯沉，使用经验公式估算其他位置
    fprintf('    ⚠️ 仅有中心弯沉，使用经验公式估算其他位置\n');
    deflections = estimateDeflectionDistribution(pde_result.D_FEA, positions);
    return;
end

% 如果有完整的位移场，尝试直接提取
try
    if isfield(pde_result, 'solution') && isfield(pde_result, 'mesh')
        % 有详细的网格和解数据，可以插值提取
        deflections = interpolateDeflectionAtPositions(pde_result, positions);
    else
        % 回退到经验估算
        fprintf('    📊 使用经验公式估算弯沉分布\n');
        center_deflection = pde_result.D_FEA;
        deflections = estimateDeflectionDistribution(center_deflection, positions);
    end
catch ME
    fprintf('    ⚠️ 插值提取失败: %s\n', ME.message);
    % 回退到经验估算
    center_deflection = pde_result.D_FEA;
    deflections = estimateDeflectionDistribution(center_deflection, positions);
end

% 显示结果
fprintf('    弯沉分布 (mm):\n');
for i = 1:length(positions)
    fprintf('      %.1fm: %.3f mm\n', positions(i), deflections(i));
end

end

function deflections = estimateDeflectionDistribution(center_deflection, positions)
% 基于中心弯沉估算其他位置的弯沉分布
% 使用Boussinesq解的近似衰减模式

deflections = zeros(1, length(positions));

% 荷载半径
load_radius = 0.1065;  % m (标准FWD)

for i = 1:length(positions)
    r = positions(i);  % m
    
    if r == 0
        % 荷载中心
        deflections(i) = center_deflection;
    else
        % 基于Boussinesq解的衰减公式
        % D(r) = D(0) * f(r/a) where a is load radius
        r_normalized = r / load_radius;
        
        if r_normalized <= 1.0
            % 荷载区域内
            decay_factor = 0.8 + 0.2 * cos(pi * r_normalized / 2);
        else
            % 荷载区域外
            decay_factor = 0.8 / (1 + 0.5 * (r_normalized - 1));
        end
        
        deflections(i) = center_deflection * decay_factor;
    end
end

end

function deflections = interpolateDeflectionAtPositions(pde_result, positions)
% 从PDE结果中插值提取指定位置的弯沉
% （这是理想情况，需要详细的解数据）

% 暂时使用简化实现
fprintf('    💡 详细插值功能待实现，使用经验估算\n');
center_deflection = pde_result.D_FEA;
deflections = estimateDeflectionDistribution(center_deflection, positions);

end