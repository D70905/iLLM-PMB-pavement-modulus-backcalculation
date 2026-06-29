function config = loadBackcalculationConfig(config_file)
% LOADBACKCALCULATIONCONFIG 加载路面反演项目配置
%
% 功能：
%   从JSON配置文件加载项目配置，如果文件不存在则使用默认配置
%   自动识别 config_backcalculation.json 或 config_ablation.json
%
% 输入：
%   config_file - 配置文件路径（可选）
%                 默认优先查找 config_backcalculation.json
%
% 输出：
%   config - 配置结构体
%
% 使用示例：
%   config = loadBackcalculationConfig();                          % 使用默认路径
%   config = loadBackcalculationConfig('my_config.json');          % 指定配置文件
%
% 作者：基于iLLM-PMB项目
% 日期：2025-11

if nargin < 1 || isempty(config_file)
    % 默认配置文件路径 - 按优先级搜索
    possible_paths = {
        'config_backcalculation.json',                              % 当前目录
        '../config_backcalculation.json',                           % 上级目录
        fullfile(fileparts(mfilename('fullpath')), 'config_backcalculation.json'),  % 相对于此文件
        fullfile(pwd, 'config_backcalculation.json'),              % 工作目录
        fullfile(fileparts(mfilename('fullpath')), '..', 'config_backcalculation.json'),
        'config_ablation.json',                                     % 备选：消融实验配置
        '../config_ablation.json'
    };
    
    config_file = '';
    for i = 1:length(possible_paths)
        if exist(possible_paths{i}, 'file')
            config_file = possible_paths{i};
            break;
        end
    end
end

% 尝试加载配置文件
if ~isempty(config_file) && exist(config_file, 'file')
    try
        fprintf('加载配置文件: %s\n', config_file);
        fid = fopen(config_file, 'r', 'n', 'UTF-8');
        raw = fread(fid, inf, 'uint8=>char')';
        fclose(fid);
        config = jsondecode(raw);
        fprintf('  ✓ 配置文件加载成功\n');
        
        % 验证并补充缺失字段
        config = validateAndCompleteConfig(config);
        return;
    catch ME
        fprintf('  ⚠️ 配置文件加载失败: %s\n', ME.message);
        fprintf('  使用默认配置\n');
    end
end

% 如果未找到配置文件或加载失败，使用默认配置
fprintf('使用默认配置\n');
config = getDefaultConfig();

end

%% ==================== 辅助函数 ====================

function config = validateAndCompleteConfig(config)
% 验证配置并补充缺失字段

% 确保必要的顶层字段存在
default_config = getDefaultConfig();

% LLM引导配置
if ~isfield(config, 'llm_guidance')
    config.llm_guidance = default_config.llm_guidance;
else
    config.llm_guidance = mergeStructs(default_config.llm_guidance, config.llm_guidance);
end

% 反演配置
if ~isfield(config, 'backcalculation')
    config.backcalculation = default_config.backcalculation;
else
    config.backcalculation = mergeStructs(default_config.backcalculation, config.backcalculation);
end

% PPO配置
if ~isfield(config, 'ppo_backcalculation')
    config.ppo_backcalculation = default_config.ppo_backcalculation;
else
    config.ppo_backcalculation = mergeStructs(default_config.ppo_backcalculation, config.ppo_backcalculation);
end

% 模量约束
if ~isfield(config, 'modulus_constraints')
    config.modulus_constraints = default_config.modulus_constraints;
else
    config.modulus_constraints = mergeStructs(default_config.modulus_constraints, config.modulus_constraints);
end

% 奖励权重
if ~isfield(config, 'reward_weights_backcalculation')
    config.reward_weights_backcalculation = default_config.reward_weights_backcalculation;
else
    config.reward_weights_backcalculation = mergeStructs(default_config.reward_weights_backcalculation, ...
                                                         config.reward_weights_backcalculation);
end

% 输出配置
if ~isfield(config, 'output')
    config.output = default_config.output;
else
    config.output = mergeStructs(default_config.output, config.output);
end

% 验证配置
if ~isfield(config, 'validation')
    config.validation = default_config.validation;
else
    config.validation = mergeStructs(default_config.validation, config.validation);
end

% 测量数据配置（可选）
if ~isfield(config, 'measurement_data') && isfield(default_config, 'measurement_data')
    config.measurement_data = default_config.measurement_data;
elseif isfield(config, 'measurement_data') && isfield(default_config, 'measurement_data')
    config.measurement_data = mergeStructs(default_config.measurement_data, config.measurement_data);
end

% LLM API配置
llm_models = {'deepseek', 'qwen', 'gpt4o', 'glm4', 'claude', 'gemini'};
for i = 1:length(llm_models)
    model = llm_models{i};
    if ~isfield(config, model) && isfield(default_config, model)
        config.(model) = default_config.(model);
    elseif isfield(config, model) && isfield(default_config, model)
        config.(model) = mergeStructs(default_config.(model), config.(model));
    end
end

% 确保关键字段存在
if ~isfield(config.llm_guidance, 'use_verification')
    config.llm_guidance.use_verification = true;
end
if ~isfield(config.llm_guidance, 'min_verification_score')
    config.llm_guidance.min_verification_score = 60;
end
if ~isfield(config.llm_guidance, 'verification_level')
    config.llm_guidance.verification_level = 'moderate';
end

end

function merged = mergeStructs(default_struct, user_struct)
% 合并两个结构体，用户配置覆盖默认配置

merged = default_struct;
fields = fieldnames(user_struct);

for i = 1:length(fields)
    field = fields{i};
    if isstruct(user_struct.(field)) && isfield(merged, field) && isstruct(merged.(field))
        % 递归合并子结构体
        merged.(field) = mergeStructs(merged.(field), user_struct.(field));
    else
        % 直接覆盖
        merged.(field) = user_struct.(field);
    end
end

end

function config = getDefaultConfig()
% 获取默认配置

config = struct();

% ==================== 反演计算基础设置 ====================
config.backcalculation = struct();
config.backcalculation.description = '反演计算基础设置';
config.backcalculation.optimization_target = 'modulus_only';
config.backcalculation.convergence_threshold = 0.05;
config.backcalculation.max_iterations = 50;
config.backcalculation.tolerance_deflection_mm = 0.1;

% ==================== PPO配置 ====================
config.ppo_backcalculation = struct();
config.ppo_backcalculation.max_episodes = 50;
config.ppo_backcalculation.max_steps_per_episode = 15;
config.ppo_backcalculation.early_stop_patience = 15;
config.ppo_backcalculation.learning_rate = 0.002;
config.ppo_backcalculation.gamma = 0.95;
config.ppo_backcalculation.clip_ratio = 0.2;
config.ppo_backcalculation.value_clip = 0.2;
config.ppo_backcalculation.entropy_coeff = 0.01;
config.ppo_backcalculation.gae_lambda = 0.95;
config.ppo_backcalculation.action_dimension = 3;
config.ppo_backcalculation.state_dimension = 4;
config.ppo_backcalculation.hidden_dim = 64;
config.ppo_backcalculation.batch_size = 32;
config.ppo_backcalculation.ppo_epochs = 4;
config.ppo_backcalculation.buffer_size = 256;
config.ppo_backcalculation.reward_scale_factor = 2.0;

% ==================== 模量约束 ====================
config.modulus_constraints = struct();
config.modulus_constraints.surface_layer_min = 800;
config.modulus_constraints.surface_layer_max = 4000;
config.modulus_constraints.base_layer_min = 200;
config.modulus_constraints.base_layer_max = 1500;
config.modulus_constraints.subbase_layer_min = 60;
config.modulus_constraints.subbase_layer_max = 600;
config.modulus_constraints.unit = 'MPa';
config.modulus_constraints.enable_physical_constraints = true;

% ==================== 奖励权重 ====================
config.reward_weights_backcalculation = struct();
config.reward_weights_backcalculation.deflection_match_weight = 0.80;
config.reward_weights_backcalculation.modulus_reasonableness_weight = 0.15;
config.reward_weights_backcalculation.convergence_weight = 0.05;

% ==================== LLM引导配置 ====================
config.llm_guidance = struct();
config.llm_guidance.enabled = true;
config.llm_guidance.model = 'deepseek';
config.llm_guidance.guidance_interval = 3;
config.llm_guidance.use_for_initial_estimate = true;
config.llm_guidance.use_for_optimization_guidance = true;
config.llm_guidance.use_verification = true;
config.llm_guidance.min_verification_score = 60;
config.llm_guidance.verification_level = 'moderate';

% ==================== 测量数据配置 ====================
config.measurement_data = struct();
config.measurement_data.deflection_positions = [0, 20, 30, 60, 90, 120];
config.measurement_data.deflection_units = 'mm';
config.measurement_data.measurement_temperature = 20;
config.measurement_data.temperature_correction = true;

% ==================== 输出配置 ====================
config.output = struct();
config.output.save_results = true;
config.output.output_directory = 'output/backcalculation_results';
config.output.save_format = {'mat', 'csv', 'txt'};
config.output.generate_report = true;
config.output.plot_results = true;
config.output.verbose = true;

% ==================== 验证配置 ====================
config.validation = struct();
config.validation.enable_cross_validation = true;
config.validation.sensitivity_analysis = true;
config.validation.confidence_interval = 0.95;

% ==================== DeepSeek配置 ====================
config.deepseek = struct();
config.deepseek.api_key = '';
config.deepseek.model = 'deepseek-chat';
config.deepseek.base_url = 'https://api.deepseek.com';
config.deepseek.max_tokens = 1500;
config.deepseek.temperature = 0.1;
config.deepseek.timeout = 30;
config.deepseek.disable_ssl_verify = false;

% ==================== Qwen配置 ====================
config.qwen = struct();
config.qwen.api_key = '';
config.qwen.model = 'qwen-plus';
config.qwen.base_url = 'https://dashscope.aliyuncs.com/compatible-mode/v1';
config.qwen.max_tokens = 1500;
config.qwen.temperature = 0.1;
config.qwen.timeout = 30;
config.qwen.disable_ssl_verify = false;

% ==================== GPT-4o配置 ====================
config.gpt4o = struct();
config.gpt4o.api_key = '';
config.gpt4o.model = 'gpt-4o';
config.gpt4o.base_url = 'https://api.openai.com';
config.gpt4o.max_tokens = 1500;
config.gpt4o.temperature = 0.1;
config.gpt4o.timeout = 35;
config.gpt4o.disable_ssl_verify = false;

% ==================== GLM-4配置 ====================
config.glm4 = struct();
config.glm4.api_key = '';
config.glm4.model = 'glm-4-plus';
config.glm4.base_url = 'https://dashscope.aliyuncs.com/compatible-mode/v1';
config.glm4.max_tokens = 1500;
config.glm4.temperature = 0.1;
config.glm4.timeout = 40;
config.glm4.disable_ssl_verify = false;

% ==================== Claude配置 ====================
config.claude = struct();
config.claude.api_key = '';
config.claude.model = 'claude-3-5-sonnet-20241022';
config.claude.base_url = 'https://api.anthropic.com';
config.claude.max_tokens = 1500;
config.claude.temperature = 0.1;
config.claude.timeout = 35;
config.claude.disable_ssl_verify = false;

% ==================== Gemini配置 ====================
config.gemini = struct();
config.gemini.api_key = '';
config.gemini.model = 'gemini-2.0-flash';
config.gemini.base_url = 'https://generativelanguage.googleapis.com';
config.gemini.max_tokens = 1500;
config.gemini.temperature = 0.1;
config.gemini.timeout = 35;
config.gemini.disable_ssl_verify = false;

end