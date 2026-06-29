function [is_valid, validation_report, corrected_modulus] = verifyLLMOutput(...
    llm_modulus, input_data, config, verification_mode)
% VERIFYLLMOUTPUT LLM输出校核模块
%
% 功能:
%   对LLM输出的模量估计进行多维度校核，确保结果的可靠性和合理性
%
% 输入:
%   llm_modulus      - LLM输出的模量结构体 (surface, base, subbase)
%   input_data       - 输入数据（包含层厚、实测弯沉等）
%   config           - 配置参数
%   verification_mode - 校核模式: 'strict'(严格) 或 'moderate'(中等，默认)
%
% 输出:
%   is_valid         - 校核是否通过 (true/false)
%   validation_report - 校核报告结构体
%   corrected_modulus - 修正后的模量（如果校核失败，返回修正值）
%
% 校核内容:
%   1. 数值范围检查: 模量是否在合理工程范围内
%   2. 逻辑一致性检查: 模量是否满足递减规律
%   3. 格式完整性检查: 所有字段是否存在且为数值
%   4. 工程合理性检查: 是否符合材料类型和弯沉值的工程经验
%   5. PDE快速验证(可选): 使用PDE计算验证弯沉是否合理

if nargin < 4
    verification_mode = 'moderate';
end

% 初始化校核报告
validation_report = struct();
validation_report.checks = {};
validation_report.passed = [];
validation_report.messages = {};
validation_report.overall_score = 0;
validation_report.max_score = 0;

% 初始化修正模量
corrected_modulus = llm_modulus;

% ============= 检查1: 格式完整性检查 =============
check_name = '格式完整性';
validation_report.max_score = validation_report.max_score + 10;
check_passed = true;
check_messages = {};

if ~isstruct(llm_modulus)
    check_passed = false;
    check_messages{end+1} = 'LLM输出不是结构体格式';
else
    required_fields = {'surface', 'base', 'subbase'};
    for i = 1:length(required_fields)
        if ~isfield(llm_modulus, required_fields{i})
            check_passed = false;
            check_messages{end+1} = sprintf('缺少字段: %s', required_fields{i});
        elseif ~isnumeric(llm_modulus.(required_fields{i})) || ...
               isnan(llm_modulus.(required_fields{i})) || ...
               isinf(llm_modulus.(required_fields{i}))
            check_passed = false;
            check_messages{end+1} = sprintf('字段 %s 不是有效数值', required_fields{i});
        end
    end
end

if check_passed
    validation_report.passed(end+1) = true;
    validation_report.checks{end+1} = check_name;
    validation_report.messages{end+1} = '✓ 格式完整，所有字段存在且为有效数值';
    validation_report.overall_score = validation_report.overall_score + 10;
else
    validation_report.passed(end+1) = false;
    validation_report.checks{end+1} = check_name;
    validation_report.messages{end+1} = strjoin(check_messages, '; ');
    % 尝试修正：使用默认值
    if ~isfield(llm_modulus, 'surface') || ~isnumeric(llm_modulus.surface)
        corrected_modulus.surface = 1200;
    end
    if ~isfield(llm_modulus, 'base') || ~isnumeric(llm_modulus.base)
        corrected_modulus.base = 800;
    end
    if ~isfield(llm_modulus, 'subbase') || ~isnumeric(llm_modulus.subbase)
        corrected_modulus.subbase = 200;
    end
end

% 如果格式检查失败，直接返回
if ~check_passed
    validation_report.overall_score = 0;
    is_valid = false;
    return;
end

% ============= 检查2: 数值范围检查 =============
check_name = '数值范围';
validation_report.max_score = validation_report.max_score + 20;
check_passed = true;
check_messages = {};

% 获取模量约束范围
if isfield(config, 'modulus_constraints')
    constraints = config.modulus_constraints;
else
    % 默认约束范围
    constraints = struct();
    constraints.surface_layer_min = 500;
    constraints.surface_layer_max = 5000;
    constraints.base_layer_min = 100;
    constraints.base_layer_max = 2000;
    constraints.subbase_layer_min = 50;
    constraints.subbase_layer_max = 800;
end

% 检查表面层
if llm_modulus.surface < constraints.surface_layer_min
    check_passed = false;
    check_messages{end+1} = sprintf('表面层模量过低: %d < %d MPa', ...
        llm_modulus.surface, constraints.surface_layer_min);
    corrected_modulus.surface = constraints.surface_layer_min;
elseif llm_modulus.surface > constraints.surface_layer_max
    check_passed = false;
    check_messages{end+1} = sprintf('表面层模量过高: %d > %d MPa', ...
        llm_modulus.surface, constraints.surface_layer_max);
    corrected_modulus.surface = constraints.surface_layer_max;
end

% 检查基层
if llm_modulus.base < constraints.base_layer_min
    check_passed = false;
    check_messages{end+1} = sprintf('基层模量过低: %d < %d MPa', ...
        llm_modulus.base, constraints.base_layer_min);
    corrected_modulus.base = constraints.base_layer_min;
elseif llm_modulus.base > constraints.base_layer_max
    check_passed = false;
    check_messages{end+1} = sprintf('基层模量过高: %d > %d MPa', ...
        llm_modulus.base, constraints.base_layer_max);
    corrected_modulus.base = constraints.base_layer_max;
end

% 检查底基层
if llm_modulus.subbase < constraints.subbase_layer_min
    check_passed = false;
    check_messages{end+1} = sprintf('底基层模量过低: %d < %d MPa', ...
        llm_modulus.subbase, constraints.subbase_layer_min);
    corrected_modulus.subbase = constraints.subbase_layer_min;
elseif llm_modulus.subbase > constraints.subbase_layer_max
    check_passed = false;
    check_messages{end+1} = sprintf('底基层模量过高: %d > %d MPa', ...
        llm_modulus.subbase, constraints.subbase_layer_max);
    corrected_modulus.subbase = constraints.subbase_layer_max;
end

if check_passed
    validation_report.passed(end+1) = true;
    validation_report.checks{end+1} = check_name;
    validation_report.messages{end+1} = '✓ 所有模量值在合理工程范围内';
    validation_report.overall_score = validation_report.overall_score + 20;
else
    validation_report.passed(end+1) = false;
    validation_report.checks{end+1} = check_name;
    validation_report.messages{end+1} = strjoin(check_messages, '; ');
    validation_report.overall_score = validation_report.overall_score + 10; % 部分分数
end

% ============= 检查3: 逻辑一致性检查（模量递减规律） =============
check_name = '模量递减规律';
validation_report.max_score = validation_report.max_score + 20;
check_passed = true;
check_messages = {};

% 检查模量递减规律: 表面层 > 基层 > 底基层
if corrected_modulus.surface <= corrected_modulus.base
    check_passed = false;
    check_messages{end+1} = sprintf('表面层模量(%d) <= 基层模量(%d)，违反递减规律', ...
        corrected_modulus.surface, corrected_modulus.base);
    % 修正：确保表面层 > 基层
    corrected_modulus.base = round(corrected_modulus.surface * 0.5);
end

if corrected_modulus.base <= corrected_modulus.subbase
    check_passed = false;
    check_messages{end+1} = sprintf('基层模量(%d) <= 底基层模量(%d)，违反递减规律', ...
        corrected_modulus.base, corrected_modulus.subbase);
    % 修正：确保基层 > 底基层
    corrected_modulus.subbase = round(corrected_modulus.base * 0.4);
end

% 检查模量比例是否合理（避免差距过大或过小）
ratio_surface_base = corrected_modulus.surface / corrected_modulus.base;
ratio_base_subbase = corrected_modulus.base / corrected_modulus.subbase;

if ratio_surface_base < 1.2
    check_messages{end+1} = sprintf('表面层/基层比例过小: %.2f (建议>1.5)', ratio_surface_base);
    validation_report.overall_score = validation_report.overall_score + 5; % 部分分数
elseif ratio_surface_base > 10
    check_messages{end+1} = sprintf('表面层/基层比例过大: %.2f (建议<8)', ratio_surface_base);
    validation_report.overall_score = validation_report.overall_score + 5; % 部分分数
end

if ratio_base_subbase < 1.2
    check_messages{end+1} = sprintf('基层/底基层比例过小: %.2f (建议>1.5)', ratio_base_subbase);
    validation_report.overall_score = validation_report.overall_score + 5; % 部分分数
elseif ratio_base_subbase > 8
    check_messages{end+1} = sprintf('基层/底基层比例过大: %.2f (建议<6)', ratio_base_subbase);
    validation_report.overall_score = validation_report.overall_score + 5; % 部分分数
end

if check_passed && isempty(check_messages)
    validation_report.passed(end+1) = true;
    validation_report.checks{end+1} = check_name;
    validation_report.messages{end+1} = '✓ 模量满足递减规律，比例合理';
    validation_report.overall_score = validation_report.overall_score + 20;
else
    validation_report.passed(end+1) = check_passed;
    validation_report.checks{end+1} = check_name;
    if isempty(check_messages)
        validation_report.messages{end+1} = '✓ 模量满足递减规律';
    else
        validation_report.messages{end+1} = strjoin(check_messages, '; ');
    end
    if check_passed
        validation_report.overall_score = validation_report.overall_score + 15; % 部分分数
    else
        validation_report.overall_score = validation_report.overall_score + 10; % 修正后给部分分数
    end
end

% ============= 检查4: 工程合理性检查 =============
check_name = '工程合理性';
validation_report.max_score = validation_report.max_score + 30;
check_passed = true;
check_messages = {};
score = 0;

% 4.1 材料类型合理性
% 表面层(沥青混凝土): 典型范围 800-3000 MPa
if corrected_modulus.surface >= 800 && corrected_modulus.surface <= 3000
    score = score + 10;
    check_messages{end+1} = '表面层模量符合沥青混凝土典型范围';
else
    check_messages{end+1} = sprintf('表面层模量(%d)偏离沥青混凝土典型范围(800-3000 MPa)', ...
        corrected_modulus.surface);
end

% 基层(水泥稳定碎石): 典型范围 300-1200 MPa
if corrected_modulus.base >= 300 && corrected_modulus.base <= 1200
    score = score + 10;
    check_messages{end+1} = '基层模量符合水泥稳定碎石典型范围';
else
    check_messages{end+1} = sprintf('基层模量(%d)偏离水泥稳定碎石典型范围(300-1200 MPa)', ...
        corrected_modulus.base);
end

% 底基层(级配碎石): 典型范围 100-400 MPa
if corrected_modulus.subbase >= 100 && corrected_modulus.subbase <= 400
    score = score + 10;
    check_messages{end+1} = '底基层模量符合级配碎石典型范围';
else
    check_messages{end+1} = sprintf('底基层模量(%d)偏离级配碎石典型范围(100-400 MPa)', ...
        corrected_modulus.subbase);
end

validation_report.passed(end+1) = (score >= 20); % 至少2层合理
validation_report.checks{end+1} = check_name;
validation_report.messages{end+1} = strjoin(check_messages, '; ');
validation_report.overall_score = validation_report.overall_score + score;

% ============= 检查5: 弯沉一致性检查（基于经验公式快速估算） =============
check_name = '弯沉一致性';
validation_report.max_score = validation_report.max_score + 20;
check_passed = true;
check_messages = {};

if isfield(input_data, 'measured_deflection') && input_data.measured_deflection > 0
    % 使用简化的经验公式快速估算弯沉
    % 基于多层弹性理论的经验公式: D ≈ k * P * r / E_equivalent
    % 其中 E_equivalent 是等效模量
    
    % 计算等效模量（简化方法：加权平均，考虑层厚）
    total_thickness = sum(input_data.thickness) / 100; % 转换为米
    thickness_weights = input_data.thickness / sum(input_data.thickness);
    
    % 等效模量（考虑层厚加权）
    E_equiv = (corrected_modulus.surface * thickness_weights(1) + ...
               corrected_modulus.base * thickness_weights(2) + ...
               corrected_modulus.subbase * thickness_weights(3));
    
    % 简化的弯沉估算公式（基于Boussinesq解和经验修正）
    % D ≈ 2 * P * r / (π * E_equiv) * α
    % α 是经验修正系数，考虑多层结构和荷载分布
    if isfield(input_data, 'load_pressure') && isfield(input_data, 'load_radius')
        P = input_data.load_pressure; % MPa
        r = input_data.load_radius / 100; % 转换为米
        alpha = 0.8; % 经验修正系数（多层结构）
        
        estimated_deflection = 2 * P * 1e6 * r / (pi * E_equiv * 1e6) * alpha * 1000; % 转换为mm
        
        % 计算相对误差
        deflection_error = abs(estimated_deflection - input_data.measured_deflection) / ...
                          input_data.measured_deflection;
        
        if deflection_error < 0.3  % 30%以内认为合理
            check_passed = true;
            check_messages{end+1} = sprintf('经验估算弯沉(%.3f mm)与实测(%.3f mm)误差%.1f%%，合理', ...
                estimated_deflection, input_data.measured_deflection, deflection_error * 100);
            validation_report.overall_score = validation_report.overall_score + 20;
        elseif deflection_error < 0.5  % 50%以内可接受
            check_passed = true;
            check_messages{end+1} = sprintf('经验估算弯沉(%.3f mm)与实测(%.3f mm)误差%.1f%%，可接受', ...
                estimated_deflection, input_data.measured_deflection, deflection_error * 100);
            validation_report.overall_score = validation_report.overall_score + 10;
        else
            check_passed = false;
            check_messages{end+1} = sprintf('经验估算弯沉(%.3f mm)与实测(%.3f mm)误差%.1f%%，偏差较大', ...
                estimated_deflection, input_data.measured_deflection, deflection_error * 100);
            validation_report.overall_score = validation_report.overall_score + 5;
        end
    else
        check_messages{end+1} = '缺少荷载参数，跳过弯沉一致性检查';
        validation_report.overall_score = validation_report.overall_score + 10; % 给部分分数
    end
else
    check_messages{end+1} = '缺少实测弯沉数据，跳过弯沉一致性检查';
    validation_report.overall_score = validation_report.overall_score + 10; % 给部分分数
end

validation_report.passed(end+1) = check_passed;
validation_report.checks{end+1} = check_name;
validation_report.messages{end+1} = strjoin(check_messages, '; ');

% ============= 综合判断 =============
% 计算通过率
pass_rate = sum(validation_report.passed) / length(validation_report.passed);
score_rate = validation_report.overall_score / validation_report.max_score;

% 根据校核模式判断是否通过
if strcmpi(verification_mode, 'strict')
    % 严格模式：所有检查必须通过，且分数率>80%
    is_valid = (pass_rate == 1.0) && (score_rate >= 0.8);
else
    % 中等模式：至少80%检查通过，且分数率>70%
    is_valid = (pass_rate >= 0.8) && (score_rate >= 0.7);
end

% 更新校核报告
validation_report.pass_rate = pass_rate;
validation_report.score_rate = score_rate;
validation_report.verification_mode = verification_mode;
validation_report.is_valid = is_valid;

end


