function varargout = pdeInterface(action, varargin)
% PDEINTERFACE 统一的PDE建模接口 - 支持多点弯沉版本
%
% 功能：合并PDE相关的参数构造和计算功能，支持多点弯沉分析
%
% 用法：
%   params = pdeInterface('constructParams', input_data, modulus)
%   results = pdeInterface('performPDE', params, input_data) 
%   isValid = pdeInterface('validateResults', results, tolerance)
%   results = pdeInterface('quickCalc', input_data, modulus)  % 快速计算
%
% 输出：
%   根据action返回不同结果

% 输出：
%   根据action返回不同结果

% ================== 【终极修复 v7.3】类型强制转换 ==================
    % 1. 解包 Cell (如果是元胞数组)
    if iscell(action)
        raw_action = action{1};
    else
        raw_action = action;
    end
    
    % 2. 强制转换为字符向量 (Char Vector)
    % string("Text") -> 'Text'
    % 'Text' -> 'Text'
    try
        action_char = char(raw_action); 
    catch
        error('pdeInterface:InvalidAction', 'Action 参数无法转换为字符向量');
    end
    
    % 3. 统一转换为小写并在 switch 中使用
    switch lower(action)
        case 'constructparams'
            if nargout > 1
                error('constructParams只返回一个输出参数');
            end
            varargout{1} = constructPDEParams(varargin{:});

        case 'performpde'
            if nargout > 1
                error('performPDE只返回一个输出参数');
            end
            varargout{1} = performMultipointPDE(varargin{:});

        case 'validateresults'
            if nargout > 1
                error('validateResults只返回一个输出参数');
            end
            varargout{1} = validatePDEResults(varargin{:});

        case 'quickcalc'
            % 快速计算：一次性完成参数构造和PDE计算
            if nargin < 3
                error('quickCalc需要至少2个输入参数：input_data, modulus');
            end
            input_data = varargin{1};
            modulus = varargin{2};

            params = constructPDEParams(input_data, modulus);
            results = performMultipointPDE(params, input_data);
            varargout{1} = results;

        case 'analyzebasin'
            % 弯沉盆分析
            if nargin < 3
                error('analyzeBasin需要至少2个输入参数：deflections, deflection_points');
            end
            deflections = varargin{1};
            deflection_points = varargin{2};
            varargout{1} = analyzeDeflectionBasin(deflections, deflection_points);

        otherwise
            error('不支持的操作: %s', action);
    end

end

%% ==================== PDE参数构造 ====================

function params = constructPDEParams(input_data, modulus)
% CONSTRUCTPDEPARAMS 构造PDE建模参数 - 多点弯沉版本
%
% 输入:
%   input_data - 输入数据结构体
%   modulus - 模量结构体，包含surface, base, subbase字段
%
% 输出:
%   params - PDE建模参数结构体

params = struct();

% 获取层厚
if isfield(input_data, 'thickness_cm')
    params.thickness = input_data.thickness_cm;
elseif isfield(input_data, 'thickness')
    params.thickness = input_data.thickness;
else
    error('input_data必须包含thickness或thickness_cm字段');
end

% 模量向量
params.modulus = [modulus.surface; modulus.base; modulus.subbase];

% 泊松比
if isfield(input_data, 'poisson')
    params.poisson = input_data.poisson;
else
    % 默认泊松比 [沥青层, 半刚性基层, 粒料层]
    params.poisson = [0.35; 0.25; 0.30];
end

% 材料名称
if isfield(input_data, 'layer_names')
    params.material = input_data.layer_names;
else
    params.material = {'Asphalt', 'Base', 'Subbase'};
end

% 荷载参数
if isfield(input_data, 'load_pressure')
    params.load_pressure = input_data.load_pressure;
elseif isfield(input_data, 'load_kN') && isfield(input_data, 'load_radius_cm')
    % 从荷载和半径计算压力
    load_kN = input_data.load_kN;
    radius_cm = input_data.load_radius_cm;
    area_m2 = pi * (radius_cm/100)^2;
    params.load_pressure = (load_kN * 1000) / area_m2 / 1e6;  % MPa
else
    % 默认标准轴载
    params.load_pressure = 0.707;  % MPa
end

if isfield(input_data, 'load_radius')
    params.load_radius = input_data.load_radius;
elseif isfield(input_data, 'load_radius_cm')
    params.load_radius = input_data.load_radius_cm;
else
    params.load_radius = 15;  % cm
end

% 地基模型类型选择
if isfield(input_data, 'subgrade_modeling') && ~isempty(input_data.subgrade_modeling)
    params.subgrade_modeling = input_data.subgrade_modeling;
else
    % 默认使用multilayer_subgrade（适合反演）
    params.subgrade_modeling = 'multilayer_subgrade';
end

% 土基模量参数
if isfield(input_data, 'subgrade_modulus') && input_data.subgrade_modulus > 0
    params.subgrade_modulus = input_data.subgrade_modulus;
else
    params.subgrade_modulus = 40;  % MPa，默认值
end

% 多点弯沉设置
params.multipoint_analysis = true;
params.deflection_points = [0, 30, 60, 90, 120, 150, 180];  % cm

end

%% ==================== 多点弯沉PDE建模执行 ====================

function pde_results = performMultipointPDE(params, input_data)
% PERFORMMULTIPOINTPDE 执行多点弯沉PDE建模计算
%
% 输入:
%   params - PDE建模参数结构体
%   input_data - 输入数据结构体
%
% 输出:
%   pde_results - PDE计算结果，包含多点弯沉

% 构造设计参数
designParams = struct();
designParams.thickness = params.thickness;
designParams.modulus = params.modulus;
designParams.poisson = params.poisson;
if isfield(params, 'material')
    designParams.material = params.material;
end

% 构造荷载参数
loadParams = struct();
loadParams.load_pressure = params.load_pressure;
loadParams.load_radius = params.load_radius;

% 构造边界条件
boundary_conditions = struct();
if isfield(params, 'subgrade_modeling')
    boundary_conditions.modeling_type = params.subgrade_modeling;
else
    boundary_conditions.modeling_type = 'multilayer_subgrade';
end

if isfield(params, 'subgrade_modulus')
    boundary_conditions.subgrade_modulus = params.subgrade_modulus;
end

% 调用新的多点弯沉PDE建模
try
    fprintf('    🔧 调用多点弯沉PDE建模...\n');
    pde_results = multipointDeflectionPDE(designParams, loadParams, boundary_conditions);
    
    % 验证计算结果
    if ~pde_results.success
        fprintf('    ⚠️ 多点PDE计算失败: %s\n', pde_results.error_message);
        % 创建后备结果
        pde_results = createBackupResults(input_data);
    else
        fprintf('    ✅ 多点PDE计算成功\n');
        fprintf('    📊 弯沉结果: [%s] mm\n', sprintf('%.4f ', pde_results.deflections));
    end
    
catch ME
    fprintf('    ❌ 多点PDE建模异常: %s\n', ME.message);
    pde_results = createBackupResults(input_data);
end

end

%% ==================== 后备结果生成 ====================

function backup_results = createBackupResults(input_data)
% 创建后备计算结果（当PDE失败时使用）

% 使用经验关系估算多点弯沉
if isfield(input_data, 'measured_deflection')
    D0 = input_data.measured_deflection;
elseif isfield(input_data, 'multipoint_deflections') && ~isempty(input_data.multipoint_deflections)
    D0 = input_data.multipoint_deflections(1);
else
    D0 = 0.8;  % 默认中心弯沉
end

% 多点弯沉位置和经验衰减系数
deflection_points = [0, 30, 60, 90, 120, 150, 180];  % cm
decay_ratios = [1.0, 0.75, 0.55, 0.40, 0.28, 0.18, 0.12];  % 经验衰减比例

% 计算多点弯沉
multipoint_deflections = D0 * decay_ratios;

backup_results = struct();
backup_results.success = false;
backup_results.D_FEA = D0;
backup_results.deflections = multipoint_deflections;
backup_results.deflection_points = deflection_points;
backup_results.method = 'empirical_fallback';
backup_results.error_message = 'PDE计算失败，使用经验关系';

fprintf('    📝 使用经验关系生成后备结果: [%s] mm\n', ...
    sprintf('%.4f ', multipoint_deflections));

end

%% ==================== PDE结果验证 ====================

function isValid = validatePDEResults(pde_results, tolerance)
% VALIDATEPDERESULTS 验证PDE计算结果的有效性 - 多点弯沉版本
%
% 输入:
%   pde_results - PDE计算结果
%   tolerance - 可选，容忍的异常值范围
%
% 输出:
%   isValid - 逻辑值，表示结果是否有效

if nargin < 2
    tolerance = struct();
    tolerance.deflection_range = [0.001, 15];  % mm，合理的弯沉范围
    tolerance.max_d0_ratio = 5.0;              % 各点与中心弯沉的最大比值
    tolerance.min_decay_rate = 0.05;           % 最小衰减率（相邻点最小比值）
end

isValid = true;

% 1. 检查必要字段
required_fields = {'deflections', 'deflection_points', 'D_FEA'};
for i = 1:length(required_fields)
    if ~isfield(pde_results, required_fields{i})
        fprintf('    ❌ PDE结果缺少字段: %s\n', required_fields{i});
        isValid = false;
        return;
    end
end

% 2. 检查数据有效性
deflections = pde_results.deflections;
deflection_points = pde_results.deflection_points;

if isempty(deflections) || any(isnan(deflections)) || any(~isreal(deflections))
    fprintf('    ❌ 多点弯沉数据无效\n');
    isValid = false;
    return;
end

% 3. 检查数值范围
if any(deflections < tolerance.deflection_range(1)) || any(deflections > tolerance.deflection_range(2))
    out_of_range = deflections < tolerance.deflection_range(1) | deflections > tolerance.deflection_range(2);
    fprintf('    ⚠️ 弯沉值超出合理范围: [%s] mm\n', sprintf('%.4f ', deflections(out_of_range)));
    isValid = false;
end

% 4. 检查弯沉盆形状合理性
if length(deflections) >= 2
    % 4.1 中心弯沉应该是最大值（或接近最大值）
    [max_deflection, max_idx] = max(deflections);
    if max_idx > 2  % 允许第一或第二点为最大值
        fprintf('    ⚠️ 弯沉盆形状异常：最大弯沉不在中心区域\n');
        isValid = false;
    end
    
    % 4.2 检查衰减趋势
    for i = 2:length(deflections)
        ratio = deflections(i) / deflections(1);
        if ratio > 1.2  % 允许小幅增长
            fprintf('    ⚠️ 弯沉衰减异常：D%d/D0 = %.2f > 1.2\n', ...
                deflection_points(i), ratio);
            isValid = false;
        end
    end
    
    % 4.3 检查相邻点变化率
    if length(deflections) >= 3
        for i = 2:length(deflections)-1
            if deflections(i-1) > 0
                change_rate = abs(deflections(i+1) - deflections(i-1)) / deflections(i-1);
                if change_rate > 2.0  % 相邻点变化不应超过200%
                    fprintf('    ⚠️ 相邻弯沉变化过大：位置%d-%d\n', ...
                        deflection_points(i-1), deflection_points(i+1));
                    isValid = false;
                end
            end
        end
    end
end

% 5. 检查计算成功标志
if isfield(pde_results, 'success') && ~pde_results.success
    fprintf('    ❌ PDE计算标记为失败\n');
    if isfield(pde_results, 'error_message')
        fprintf('    错误信息: %s\n', pde_results.error_message);
    end
    isValid = false;
end

% 6. 检查与单点弯沉的一致性
if abs(pde_results.D_FEA - deflections(1)) > 0.001
    fprintf('    ⚠️ D_FEA与deflections(1)不一致\n');
    isValid = false;
end

% 汇总验证结果
if isValid
    fprintf('    ✅ 多点弯沉结果验证通过\n');
    fprintf('    📊 弯沉范围: %.4f - %.4f mm\n', min(deflections), max(deflections));
    fprintf('    📊 衰减比: D180/D0 = %.3f\n', deflections(end)/deflections(1));
else
    fprintf('    ❌ 多点弯沉结果验证失败\n');
end

end

%% ==================== 弯沉盆分析功能 ====================

function analysis_result = analyzeDeflectionBasin(deflections, deflection_points)
% 分析弯沉盆特征参数
%
% 输入：
%   deflections - 弯沉值向量 (mm)
%   deflection_points - 对应距离向量 (cm)
%
% 输出：
%   analysis_result - 弯沉盆分析结果结构体

analysis_result = struct();

% 基本统计
analysis_result.D0 = deflections(1);                    % 中心弯沉
analysis_result.max_deflection = max(deflections);      % 最大弯沉
analysis_result.min_deflection = min(deflections);      % 最小弯沉
analysis_result.deflection_range = max(deflections) - min(deflections);

% 形状参数（基于标准FWD分析方法）
if length(deflections) >= 4
    % D30/D0 比值（表面结构指标）
    if length(deflections) >= 2
        analysis_result.D30_D0_ratio = deflections(2) / deflections(1);
    end
    
    % D60/D0 比值（整体结构指标）
    if length(deflections) >= 3
        analysis_result.D60_D0_ratio = deflections(3) / deflections(1);
    end
    
    % D90/D0 比值（基层指标）
    if length(deflections) >= 4
        analysis_result.D90_D0_ratio = deflections(4) / deflections(1);
    end
    
    % 表面模量指数（Surface Modulus Index, SMI）
    if length(deflections) >= 3
        analysis_result.SMI = deflections(1) / deflections(3);  % D0/D60
    end
    
    % 基层模量指数（Base Layer Index, BLI）
    if length(deflections) >= 4
        analysis_result.BLI = (deflections(2) - deflections(4)) / deflections(1);  % (D30-D90)/D0
    end
end

% 衰减特征分析
distances_m = deflection_points / 100;  % 转换为米
if length(distances_m) >= 3 && length(deflections) >= 3
    try
        % 拟合指数衰减模型: D = D0 * exp(-α * r)
        valid_idx = distances_m > 0 & deflections > 0;
        if sum(valid_idx) >= 2
            x_data = distances_m(valid_idx);
            y_data = log(deflections(valid_idx) / deflections(1));
            
            % 线性拟合 ln(D/D0) = -α * r
            p = polyfit(x_data, y_data, 1);
            analysis_result.decay_coefficient = -p(1);  % 衰减系数
            
            % 计算拟合优度
            y_fit = polyval(p, x_data);
            ss_res = sum((y_data - y_fit).^2);
            ss_tot = sum((y_data - mean(y_data)).^2);
            analysis_result.decay_r_squared = 1 - (ss_res / ss_tot);
            
            % 特征衰减距离（衰减到63%的距离）
            analysis_result.characteristic_length = 1 / analysis_result.decay_coefficient;  % 米
        end
    catch
        analysis_result.decay_coefficient = NaN;
        analysis_result.decay_r_squared = NaN;
        analysis_result.characteristic_length = NaN;
    end
end

% 结构状态评估（基于中国规范）
if analysis_result.D0 <= 0.20
    analysis_result.structure_condition = '优秀';
    analysis_result.condition_score = 95;
elseif analysis_result.D0 <= 0.40
    analysis_result.structure_condition = '良好';  
    analysis_result.condition_score = 85;
elseif analysis_result.D0 <= 0.80
    analysis_result.structure_condition = '中等';
    analysis_result.condition_score = 70;
elseif analysis_result.D0 <= 1.20
    analysis_result.structure_condition = '较差';
    analysis_result.condition_score = 50;
else
    analysis_result.structure_condition = '很差';
    analysis_result.condition_score = 30;
end

% 层状结构诊断
analysis_result.diagnosis = struct();

% 表面层诊断（基于D30/D0比值）
if isfield(analysis_result, 'D30_D0_ratio')
    if analysis_result.D30_D0_ratio > 0.85
        analysis_result.diagnosis.surface_layer = '表面层刚度不足';
    elseif analysis_result.D30_D0_ratio < 0.60
        analysis_result.diagnosis.surface_layer = '表面层过硬或厚度不足';
    else
        analysis_result.diagnosis.surface_layer = '表面层状态正常';
    end
end

% 基层诊断（基于BLI指标）
if isfield(analysis_result, 'BLI')
    if analysis_result.BLI < 0.15
        analysis_result.diagnosis.base_layer = '基层承载能力不足';
    elseif analysis_result.BLI > 0.40
        analysis_result.diagnosis.base_layer = '基层过硬';
    else
        analysis_result.diagnosis.base_layer = '基层状态正常';
    end
end

% 整体结构均匀性
deflection_cv = std(deflections) / mean(deflections);  % 变异系数
if deflection_cv < 0.3
    analysis_result.uniformity = '均匀';
elseif deflection_cv < 0.6
    analysis_result.uniformity = '较均匀';
else
    analysis_result.uniformity = '不均匀';
end

fprintf('  📊 弯沉盆分析完成:\n');
fprintf('    中心弯沉: %.4f mm\n', analysis_result.D0);
fprintf('    结构状态: %s (评分: %d)\n', analysis_result.structure_condition, analysis_result.condition_score);
fprintf('    结构均匀性: %s\n', analysis_result.uniformity);
if isfield(analysis_result, 'decay_coefficient') && ~isnan(analysis_result.decay_coefficient)
    fprintf('    衰减系数: %.3f m⁻¹\n', analysis_result.decay_coefficient);
end

end

%% ==================== 可视化功能 ====================

function plotDeflectionBasin(deflections, deflection_points, title_str)
% 绘制弯沉盆曲线
%
% 输入：
%   deflections - 弯沉值 (mm)
%   deflection_points - 距离 (cm)
%   title_str - 图题

if nargin < 3, title_str = '多点弯沉盆曲线'; end

try
    figure('Name', title_str, 'Position', [100, 100, 800, 600]);
    
    % 主图：弯沉盆曲线
    subplot(2, 2, [1, 2]);
    plot(deflection_points, deflections, 'bo-', 'LineWidth', 2.5, 'MarkerSize', 8, 'MarkerFaceColor', 'b');
    grid on;
    xlabel('距荷载中心距离 (cm)', 'FontSize', 12);
    ylabel('弯沉值 (mm)', 'FontSize', 12);
    title(title_str, 'FontSize', 14, 'FontWeight', 'bold');
    
    % 添加数据标签
    for i = 1:length(deflections)
        text(deflection_points(i), deflections(i) + max(deflections)*0.05, ...
            sprintf('%.3f', deflections(i)), ...
            'HorizontalAlignment', 'center', 'FontSize', 10, 'FontWeight', 'bold');
    end
    
    % 设置坐标轴
    xlim([min(deflection_points)-15, max(deflection_points)+15]);
    ylim([0, max(deflections)*1.3]);
    
    % 子图1：衰减特性
    subplot(2, 2, 3);
    distances_m = deflection_points / 100;
    valid_idx = distances_m > 0;
    if sum(valid_idx) >= 2
        semilogy(distances_m(valid_idx), deflections(valid_idx), 'ro-', 'LineWidth', 2);
        grid on;
        xlabel('距离 (m)');
        ylabel('弯沉 (mm, 对数)');
        title('衰减特性');
    end
    
    % 子图2：形状参数
    subplot(2, 2, 4);
    if length(deflections) >= 4
        ratios = deflections(2:end) / deflections(1);
        bar(deflection_points(2:end), ratios, 'FaceColor', [0.7, 0.7, 0.9]);
        xlabel('距离 (cm)');
        ylabel('与D0的比值');
        title('形状参数');
        grid on;
    end
    
    % 调整布局
    sgtitle(['弯沉盆分析 - ', title_str], 'FontSize', 16, 'FontWeight', 'bold');
    
catch ME
    fprintf('⚠️ 绘图失败: %s\n', ME.message);
end

end