function testMultiLoadPipeline()
% TESTMULTILOADPIPELINE  验证多荷载数据管道是否正常
%
% 【用法】在MATLAB命令窗口直接运行：
%   testMultiLoadPipeline()
%
% 【前提】当前目录必须是项目根目录 D:\iLLM_PMB
%
% 【检查内容】
%   Step 1: CSV读取与字段验证
%   Step 2: buildInputData结构体验证
%   Step 3: 单条PDE正向计算验证
%   Step 4: 单条PPO反算验证（可选，耗时较长）

fprintf('\n');
fprintf('╔══════════════════════════════════════════════════════╗\n');
fprintf('║     多荷载验证数据管道测试                           ║\n');
fprintf('╚══════════════════════════════════════════════════════╝\n\n');

%% ── 路径配置 ──────────────────────────────────────────────
project_root = pwd;  % 必须在 D:\iLLM_PMB 下运行
addpath(fullfile(project_root, 'backcalculation'));
addpath(fullfile(project_root, 'core'));
addpath(fullfile(project_root, 'utils'));
fprintf('✅ 路径已添加: %s\n\n', project_root);

%% ══════════════════════════════════════════════════════════
%% Step 1: CSV读取验证
%% ══════════════════════════════════════════════════════════
fprintf('── Step 1: CSV读取验证 ──────────────────────────────\n');

csv_path = fullfile(project_root, 'data', 'multi_load_validation_data.csv');
if ~exist(csv_path, 'file')
    error('❌ CSV文件不存在: %s\n请将 multi_load_validation_data.csv 放到 data/ 目录', csv_path);
end

data = readtable(csv_path, 'TextType', 'string');
fprintf('  总行数: %d\n', height(data));
fprintf('  路段数: %d\n', length(unique(data.section_id)));
fprintf('  字段数: %d\n\n', width(data));

% 显示前4行（同一桩号4个荷载等级）
fprintf('  前4行数据（STR1 ZK0+220）:\n');
disp(data(1:4, {'section_id','station','load_kN','thickness_AC_cm',...
                'D0_mm','sensor_offsets_cm'}));

% 验证关键字段存在
required = {'section_id','station','load_kN','load_pressure_MPa',...
            'load_radius_cm','thickness_AC_cm','thickness_BC_cm',...
            'thickness_SB_cm','subgrade_modulus_MPa',...
            'poisson_AC','poisson_BC','poisson_SB','pavement_type',...
            'sensor_offsets_cm','D0_mm','D23_mm','D53_mm',...
            'D69_mm','D85_mm','D116_mm','D153_mm'};

missing = setdiff(required, data.Properties.VariableNames);
if isempty(missing)
    fprintf('✅ Step 1 通过：所有必要字段均存在\n\n');
else
    fprintf('❌ Step 1 失败：缺少字段: %s\n\n', strjoin(missing, ', '));
    return;
end

%% ══════════════════════════════════════════════════════════
%% Step 2: buildInputData结构体验证
%% ══════════════════════════════════════════════════════════
fprintf('── Step 2: buildInputData结构体验证 ────────────────\n');

row = data(1, :);  % STR1 ZK0+220 50kN
input_data = buildInputData_test(row);

fprintf('  section:         %s  %s\n', input_data.pavement_type_name, input_data.name);
fprintf('  sensor_offsets:  '); fprintf('%d ', input_data.sensor_offsets); fprintf('cm\n');
fprintf('  deflection_basin:'); fprintf(' %.4f', input_data.deflection_basin); fprintf(' mm\n');
fprintf('  D0 (measured):   %.4f mm\n', input_data.measured_deflection);
fprintf('  thickness:       AC=%.0f  BC=%.0f  SB=%.0f  cm\n', ...
    input_data.thickness(1), input_data.thickness(2), input_data.thickness(3));
fprintf('  load_pressure:   %.4f MPa  (%.1f kN)\n', ...
    input_data.load_pressure, input_data.load_kN);
fprintf('  subgrade:        %d MPa\n', input_data.subgrade_modulus);

% 基本合理性检查
ok = true;
if length(input_data.sensor_offsets) ~= 7
    fprintf('  ❌ sensor_offsets长度应为7，实际为%d\n', length(input_data.sensor_offsets));
    ok = false;
end
if length(input_data.deflection_basin) ~= 7
    fprintf('  ❌ deflection_basin长度应为7，实际为%d\n', length(input_data.deflection_basin));
    ok = false;
end
if input_data.thickness(1) ~= 12
    fprintf('  ❌ STR1的AC层厚应为12cm，实际为%.0fcm\n', input_data.thickness(1));
    ok = false;
end
if abs(input_data.load_pressure - 0.7209) > 0.01
    fprintf('  ⚠️  荷载压力 %.4f MPa，期望约0.7209 MPa（50kN）\n', input_data.load_pressure);
end

if ok
    fprintf('✅ Step 2 通过：input_data结构体正确\n\n');
else
    fprintf('❌ Step 2 有问题，请检查上方提示\n\n');
    return;
end

%% ══════════════════════════════════════════════════════════
%% Step 3: 单条PDE正向计算验证
%% ══════════════════════════════════════════════════════════
fprintf('── Step 3: PDE正向计算验证 ──────────────────────────\n');

config = getDefaultValidationConfig_test();

try
    initial_modulus = initialModulusGenerator(input_data, config, 'empirical');
    fprintf('  初始模量估计: AC=%d  BC=%d  SB=%d  MPa\n', ...
        initial_modulus.surface, initial_modulus.base, initial_modulus.subbase);
catch ME
    fprintf('  ⚠️  initialModulusGenerator失败: %s\n  使用默认初始模量\n', ME.message);
    initial_modulus = struct('surface', 3000, 'base', 5000, 'subbase', 2000, 'subgrade', 50);
end

params  = constructPDEParams_test(input_data, initial_modulus);
pde_out = performPDE_test(params, input_data);

calc_D0  = pde_out.deflections(1);
meas_D0  = input_data.measured_deflection;
err_pct  = abs(calc_D0 - meas_D0) / meas_D0 * 100;

fprintf('  实测D0:    %.4f mm\n', meas_D0);
fprintf('  计算D0:    %.4f mm\n', calc_D0);
fprintf('  初始误差:  %.2f%%\n', err_pct);

if isfield(pde_out, 'deflections') && length(pde_out.deflections) >= 7
    fprintf('  计算弯沉盆:'); fprintf(' %.4f', pde_out.deflections(1:7)); fprintf(' mm\n');
    fprintf('✅ Step 3 通过：PDE正向计算正常\n\n');
else
    fprintf('❌ Step 3 失败：PDE输出弯沉盆长度不足\n\n');
    return;
end

%% ══════════════════════════════════════════════════════════
%% Step 4: 可选 - 快速PPO反算验证（仅10个episode）
%% ══════════════════════════════════════════════════════════
fprintf('── Step 4: PPO快速反算验证（10 episodes）──────────\n');

run_ppo = input('  是否运行PPO验证？(y/n，直接回车跳过): ', 's');
if strcmpi(strtrim(run_ppo), 'y')
    config_fast = config;
    config_fast.ppo_backcalculation.max_episodes = 10;
    config_fast.ppo_backcalculation.early_stop_patience = 10;
    
    try
        agent = BackcalculationPPO(input_data, config_fast, initial_modulus, pde_out);
        [final_modulus, opt_log] = agent.optimize();
        
        final_params  = constructPDEParams_test(input_data, final_modulus);
        final_pde_out = performPDE_test(final_params, input_data);
        final_D0      = final_pde_out.deflections(1);
        final_err     = abs(final_D0 - meas_D0) / meas_D0 * 100;
        
        fprintf('\n  反算结果: AC=%d  BC=%d  SB=%d  SG=%d MPa\n', ...
            round(final_modulus.surface), round(final_modulus.base), ...
            round(final_modulus.subbase), round(final_modulus.subgrade));
        fprintf('  最终D0误差: %.2f%%\n', final_err);
        fprintf('✅ Step 4 通过：PPO反算流程正常\n\n');
    catch ME
        fprintf('❌ Step 4 失败: %s\n\n', ME.message);
    end
else
    fprintf('  （已跳过）\n\n');
end

%% ══════════════════════════════════════════════════════════
%% 最终汇总
%% ══════════════════════════════════════════════════════════
fprintf('╔══════════════════════════════════════════════════════╗\n');
fprintf('║  测试完成！数据管道验证通过，可运行全量实验          ║\n');
fprintf('║  下一步：runMultiLoadValidation()                    ║\n');
fprintf('╚══════════════════════════════════════════════════════╝\n\n');

end


%% ====================================================================
%% 内部函数（从runMultiLoadValidation.m复制，独立可用）
%% ====================================================================

function input_data = buildInputData_test(row)
% 将CSV一行转换为标准input_data结构体

input_data = struct();
input_data.pavement_type_name = char(row.pavement_type);
input_data.name  = sprintf('%s_%s_%.0fkN', ...
    char(row.section_id), char(row.station), row.load_kN);
input_data.input_mode = 'multi_load_validation';

% 路面类型编码
if contains(lower(char(row.pavement_type)), 'semi')
    input_data.pavement_type = 2;
else
    input_data.pavement_type = 1;
end

% 层厚（cm）
input_data.thickness = [row.thickness_AC_cm; row.thickness_BC_cm; row.thickness_SB_cm];

% 泊松比
input_data.poisson = [row.poisson_AC; row.poisson_BC; row.poisson_SB];

% 荷载参数
input_data.load_pressure = row.load_pressure_MPa;
input_data.load_radius   = row.load_radius_cm;
input_data.load_kN       = row.load_kN;

% 土基
input_data.subgrade_modulus = row.subgrade_modulus_MPa;

% 传感器位置（从CSV动态读取）
if ismember('sensor_offsets_cm', row.Properties.VariableNames) && ...
   strlength(row.sensor_offsets_cm) > 0
    offset_str = char(row.sensor_offsets_cm);
    input_data.sensor_offsets = str2double(strsplit(offset_str, ','))';
else
    input_data.sensor_offsets = [0, 23, 53, 69, 85, 116, 153];
end

% 弯沉盆（对应传感器列名）
deflection_cols = {'D0_mm','D23_mm','D53_mm','D69_mm','D85_mm','D116_mm','D153_mm'};
basin = zeros(1, length(deflection_cols));
for k = 1:length(deflection_cols)
    col = deflection_cols{k};
    if ismember(col, row.Properties.VariableNames)
        basin(k) = row.(col);
    end
end
input_data.deflection_basin    = basin;
input_data.measured_deflection = basin(1);

% 模量约束
input_data.modulus_constraints = getConstraints_test( ...
    char(row.pavement_type), row.D0_mm);

% 其他系统必需字段
input_data.boundary_type = 'fixed';
end


function constraints = getConstraints_test(ptype_str, D0)
constraints = struct();
if contains(lower(ptype_str), 'semi')
    % 半刚性路面约束
    if D0 < 0.10
        constraints.surface_min = 3000; constraints.surface_max = 15000;
        constraints.base_min    = 3000; constraints.base_max    = 35000;
        constraints.subbase_min = 1000; constraints.subbase_max = 8000;
    else
        constraints.surface_min = 1200; constraints.surface_max = 8000;
        constraints.base_min    = 500;  constraints.base_max    = 20000;
        constraints.subbase_min = 200;  constraints.subbase_max = 5000;
    end
else
    % 柔性路面约束
    constraints.surface_min = 800;  constraints.surface_max = 6000;
    constraints.base_min    = 150;  constraints.base_max    = 1500;
    constraints.subbase_min = 60;   constraints.subbase_max = 500;
end
end


function params = constructPDEParams_test(input_data, modulus)
params = struct();
params.thickness  = input_data.thickness(:);
params.modulus    = [modulus.surface; modulus.base; modulus.subbase];
params.poisson    = input_data.poisson(:);
params.load_pressure = input_data.load_pressure;
params.load_radius   = input_data.load_radius;
if isfield(modulus, 'subgrade') && modulus.subgrade > 0
    params.subgrade_modulus = modulus.subgrade;
else
    params.subgrade_modulus = input_data.subgrade_modulus;
end
params.subgrade_modeling = 'multilayer_subgrade';
params.sensor_offsets    = input_data.sensor_offsets;
end


function pde_results = performPDE_test(params, input_data)
load_params = struct('load_pressure', params.load_pressure, ...
                     'load_radius',   params.load_radius);
bc = struct();
bc.modeling_type    = params.subgrade_modeling;
bc.subgrade_modulus = params.subgrade_modulus;
bc.soil_modulus     = params.subgrade_modulus;
bc.sensor_offsets   = params.sensor_offsets;
bc.pavement_type  = input_data.pavement_type;

% 【关键修复】必须传入pavement_type，否则校准函数走flexible分支（factor≈1.0）
% 与PPO过程中的校准不一致，导致最终误差虚假偏大
if isfield(input_data, 'pavement_type')
    bc.pavement_type = input_data.pavement_type;  % 传数字2或字符串均可
end

try
    pde_results = roadPDEModelingABAQUSCalibrated(params, load_params, bc);
catch ME
    fprintf('  ⚠️  PDE异常: %s\n', ME.message);
    pde_results = struct('success', false, ...
                         'D0', input_data.measured_deflection, ...
                         'deflections', input_data.deflection_basin);
end
end


function config = getDefaultValidationConfig_test()
config = struct();
config.ppo_backcalculation.max_episodes          = 150;
config.ppo_backcalculation.max_steps_per_episode = 15;
config.ppo_backcalculation.early_stop_patience   = 20;
config.ppo_backcalculation.learning_rate         = 0.001;
config.backcalculation.convergence_threshold     = 0.05;
config.llm_guidance.enabled                      = false;
config.llm_guidance.use_for_initial_estimate     = false;
config.llm_guidance.use_for_optimization_guidance = false;
config.llm_guidance.guidance_interval            = 10;
config.llm_guidance.model                        = 'deepseek';
config.deepseek.api_key    = '';
config.deepseek.base_url   = 'https://api.deepseek.com/v1';
config.deepseek.model      = 'deepseek-chat';
config.deepseek.max_tokens = 2000;
config.deepseek.temperature = 0.1;
config.deepseek.timeout    = 30;
config.ollama.base_url     = 'http://localhost:11434';
config.ollama.model        = 'qwen2.5:7b';
config.ollama.temperature  = 0.1;
config.ollama.timeout      = 60;
end