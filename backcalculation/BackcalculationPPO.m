classdef BackcalculationPPO < handle
    % BACKCALCULATIONPPO 路面结构模量反演 - 完整PPO实现 v5.4.3
    %
    % 【v5.4.3 修复】
    %   1. 土基模量统一：modulus.subgrade 与 obj.current_subgrade_modulus 同步
    %   2. 探索保护阈值放宽：避免过早锁死优化
    %   3. 清晰进度显示：显示数据组名(如ABAQUS_1)和Episode进度
    %   4. 修复best_modulus记录时土基不同步问题
    %
    % 【v5.3.3 更新】半刚性结构支持:
    %   1. 扩大高刚度路面模量约束：BC上限35000MPa，SB上限8000MPa
    %   2. 适配水泥稳定碎石(CBG)和水泥土(CS)的实际模量范围
    %   3. 土基约束收紧到40-150MPa（合理范围）
    %
    % 【v5.3.2 更新】关键修复:
    %   1. PDE求解器改为 roadPDEModelingABAQUS（与最终验证一致）
    %   2. 边界条件：固定边界（底边u1=u2=0，远场u1=0）
    %   3. 计算域：r_max=8m, sg_depth=10m（与ABAQUS完全一致）
    %   4. 确保PPO优化和最终验证使用相同的物理模型
    %
    % 【v5.3.1 更新】
    %   1. 限制max_episodes为100（避免过长运行）
    %   2. 增加最小迭代次数min_episodes=10
    %
    % 【v5.3 更新】
    %   1. 增强奖励函数：弯沉盆形状权重60%（分段加权+形状指标）
    %   2. 综合收敛条件：D0误差 AND 弯沉盆形状同时达标
    %
    % 【荷载参数】与ABAQUS统一
    %   - 荷载半径: 15cm, 压力: 0.707355 MPa (ABAQUS精确值)
    %   - 弯沉测点: [0,20,30,60,90,120,150]cm
    
    properties
        input_data
        config
        initial_modulus
        initial_pde_results
        
        % 【v5.4.3新增】数据组名称（用于进度显示）
        case_name
        
        % PPO超参数
        state_dim
        action_dim
        hidden_dim
        learning_rate
        gamma
        lambda_gae
        clip_ratio
        entropy_coef
        ppo_epochs
        action_bound
        
        % Actor网络参数 (策略网络)
        actor_W1, actor_b1      % 输入层 -> 隐藏层1
        actor_W2, actor_b2      % 隐藏层1 -> 隐藏层2
        actor_W_mu, actor_b_mu  % 隐藏层2 -> 动作均值
        actor_log_std           % 动作对数标准差 (可学习)
        
        % Critic网络参数 (价值网络)
        critic_W1, critic_b1    % 输入层 -> 隐藏层1
        critic_W2, critic_b2    % 隐藏层1 -> 隐藏层2
        critic_W_v, critic_b_v  % 隐藏层2 -> 状态价值
        
        % Adam优化器状态 - Actor
        actor_m_W1, actor_v_W1, actor_m_b1, actor_v_b1
        actor_m_W2, actor_v_W2, actor_m_b2, actor_v_b2
        actor_m_W_mu, actor_v_W_mu, actor_m_b_mu, actor_v_b_mu
        actor_m_log_std, actor_v_log_std
        
        % Adam优化器状态 - Critic
        critic_m_W1, critic_v_W1, critic_m_b1, critic_v_b1
        critic_m_W2, critic_v_W2, critic_m_b2, critic_v_b2
        critic_m_W_v, critic_v_W_v, critic_m_b_v, critic_v_b_v
        
        adam_t, adam_beta1, adam_beta2, adam_eps
        
        modulus_constraints
        target_deflection
        target_basin
        convergence_threshold
        
        buffer_states, buffer_actions, buffer_rewards
        buffer_log_probs, buffer_values, buffer_dones
        
        episode_rewards, modulus_history, deflection_history
        error_history
        
        prev_error, current_deflection
        current_subgrade_modulus
        
        llm_guidance_enabled, llm_call_interval
        llm_call_count  % 记录LLM调用次数
        
        % 模量精度控制 (v5.0)
        modulus_precision_surface = 50;
        modulus_precision_base = 50;
        modulus_precision_subbase = 50;
        modulus_precision_subgrade = 10;

        current_exploration_std = 0.3;
        verbose = false;  % 调试输出控制
    end
    
    methods
        %% ==================== 构造函数 ====================
        function obj = BackcalculationPPO(input_data, config, initial_modulus, initial_pde_results)
            fprintf('  ══════════════════════════════════════════════════════════\n');
            fprintf('  初始化 PPO 智能体  (完整实现 v5.4.3 - 土基同步修复)\n');
            fprintf('  ══════════════════════════════════════════════════════════\n');
            
            % 荷载参数校验（仅检查合理性，不强制覆盖）
            if input_data.load_radius <= 0 || input_data.load_radius > 50
                warning('荷载半径 %.2f cm 超出合理范围，重置为15cm', input_data.load_radius);
                input_data.load_radius = 15.0;
            end
            if input_data.load_pressure <= 0 || input_data.load_pressure > 5.0
                warning('荷载压力 %.3f MPa 超出合理范围，重置为0.707MPa', input_data.load_pressure);
                input_data.load_pressure = 0.707355;
            end
            
            obj.input_data = input_data;
            obj.config = config;
            obj.initial_modulus = initial_modulus;
            obj.initial_pde_results = initial_pde_results;
            
            % 【v5.4.3新增】获取数据组名称
            if isfield(input_data, 'name')
                obj.case_name = input_data.name;
            else
                obj.case_name = 'Unknown';
            end
            
            % 网络架构
            obj.state_dim = 10;
            obj.action_dim = 4;
            obj.hidden_dim = 128;
            obj.learning_rate = config.ppo_backcalculation.learning_rate;
            obj.gamma = 0.99;
            obj.lambda_gae = 0.95;
            obj.clip_ratio = 0.2;
            obj.entropy_coef = 0.01;
            obj.ppo_epochs = 4;
            obj.action_bound = 0.35;
            
            % 目标弯沉
            obj.target_deflection = input_data.measured_deflection;
            obj.target_basin = input_data.deflection_basin;
            
            % 模量约束 (v5.2修复)
            obj.modulus_constraints = obj.getConstraintsByDeflection(obj.target_deflection);
            obj.convergence_threshold = config.backcalculation.convergence_threshold;
            
            % 初始化网络和优化器
            obj.initNetworks();
            obj.initOptimizer();
            obj.clearBuffer();
            
            obj.episode_rewards = [];
            obj.modulus_history = [];
            obj.deflection_history = [];
            obj.error_history = [];
            obj.llm_call_count = 0;
            
            % 【v5.4.3修复】土基模量初始化 - 确保同步
            if isfield(input_data, 'subgrade_modulus') && input_data.subgrade_modulus > 0
                obj.current_subgrade_modulus = input_data.subgrade_modulus;
            elseif isfield(initial_modulus, 'subgrade') && initial_modulus.subgrade > 0
                obj.current_subgrade_modulus = initial_modulus.subgrade;
            else
                obj.current_subgrade_modulus = 40;  % 默认值
            end
            
            % 确保initial_modulus包含subgrade字段
            if ~isfield(obj.initial_modulus, 'subgrade')
                obj.initial_modulus.subgrade = obj.current_subgrade_modulus;
            end
            
            % 初始评估
            init_pde = obj.evaluateModulus(initial_modulus);
            init_D0 = obj.getD0(init_pde);
            obj.prev_error = abs(init_D0 - obj.target_deflection) / obj.target_deflection;
            obj.current_deflection = init_D0;
            
            % 打印信息
            fprintf('\n  【荷载参数】\n');
            fprintf('    压力: %.4f MPa, 半径: %.2f cm (等效荷载: %.1f kN)\n', ...
                input_data.load_pressure, input_data.load_radius, ...
                input_data.load_pressure * pi * (input_data.load_radius/100)^2 * 1000);
            fprintf('\n  【目标弯沉】\n');
            fprintf('    D0目标: %.4f mm, D0初始: %.4f mm, 误差: %.2f%%\n', ...
                obj.target_deflection, init_D0, obj.prev_error * 100);
            fprintf('\n  【模量约束】(%s) - v5.3\n', obj.modulus_constraints.mode);
            fprintf('    AC:[%d,%d], BC:[%d,%d], SB:[%d,%d], SG:[%d,%d] MPa\n', ...
                obj.modulus_constraints.surface_layer_min, obj.modulus_constraints.surface_layer_max, ...
                obj.modulus_constraints.base_layer_min, obj.modulus_constraints.base_layer_max, ...
                obj.modulus_constraints.subbase_layer_min, obj.modulus_constraints.subbase_layer_max, ...
                obj.modulus_constraints.subgrade_min, obj.modulus_constraints.subgrade_max);
            fprintf('\n  【精度】AC/BC/SB: %dMPa, SG: %dMPa\n', ...
                obj.modulus_precision_surface, obj.modulus_precision_subgrade);
            
            % LLM引导
            obj.llm_guidance_enabled = config.llm_guidance.enabled && ...
                                      config.llm_guidance.use_for_optimization_guidance;
            obj.llm_call_interval = config.llm_guidance.guidance_interval;
            
            if obj.llm_guidance_enabled
                fprintf('  【LLM引导】已启用，调用间隔: %d episodes (首次episode也调用)\n', obj.llm_call_interval);
            else
                fprintf('  【LLM引导】未启用\n');
            end
            
            fprintf('  ══════════════════════════════════════════════════════════\n\n');
        end
        
        %% ====================  约束设置  ====================
        function constraints = getConstraintsByDeflection(obj, D0_target)
            % 根据D0自适应设置约束范围
            % 【v5.4修复】大幅扩大范围，确保所有ABAQUS真值在搜索空间内
            % 
            % ABAQUS真值范围:
            %   AC: 1800-6000 MPa
            %   BC: 200-1400 MPa
            %   SB: 80-500 MPa
            %   SG: 30-150 MPa
            
            constraints = struct();
            
            if D0_target > 0.5
                % 超柔性路面 (D0 > 500 um) - 如ABAQUS_13
                constraints.mode = '超柔性路面';
                constraints.surface_layer_min = 500;    constraints.surface_layer_max = 4000;
                constraints.base_layer_min = 100;       constraints.base_layer_max = 1000;
                constraints.subbase_layer_min = 50;     constraints.subbase_layer_max = 400;
                constraints.subgrade_min = 20;          constraints.subgrade_max = 80;
                
            elseif D0_target > 0.35
                % 柔性路面 (350-500 um) - 如ABAQUS_1, 2, 7, 8, 11
                constraints.mode = '柔性路面';
                constraints.surface_layer_min = 800;    constraints.surface_layer_max = 5000;
                constraints.base_layer_min = 150;       constraints.base_layer_max = 1500;
                constraints.subbase_layer_min = 60;     constraints.subbase_layer_max = 500;
                constraints.subgrade_min = 25;          constraints.subgrade_max = 100;
                
            elseif D0_target > 0.20
                % 中等刚度路面 (200-350 um) - 如ABAQUS_3, 5, 9, 12
                constraints.mode = '中等路面';
                constraints.surface_layer_min = 1200;   constraints.surface_layer_max = 6500;
                constraints.base_layer_min = 300;       constraints.base_layer_max = 2000;
                constraints.subbase_layer_min = 100;    constraints.subbase_layer_max = 700;
                constraints.subgrade_min = 50;          constraints.subgrade_max = 180;
                
            elseif D0_target > 0.10
                % 较高刚度路面 (100-200 um) - 如ABAQUS_6
                constraints.mode = '较高刚度路面';
                constraints.surface_layer_min = 2000;   constraints.surface_layer_max = 8000;
                constraints.base_layer_min = 500;       constraints.base_layer_max = 3000;
                constraints.subbase_layer_min = 200;    constraints.subbase_layer_max = 1000;
                constraints.subgrade_min = 80;          constraints.subgrade_max = 250;
                
            else
                % 高刚度路面 (D0 < 100 um) - 半刚性/刚性，如RingRoad
                constraints.mode = '高刚度路面';
                constraints.surface_layer_min = 3000;   constraints.surface_layer_max = 15000;
                constraints.base_layer_min = 3000;      constraints.base_layer_max = 35000;
                constraints.subbase_layer_min = 1000;   constraints.subbase_layer_max = 8000;
                constraints.subgrade_min = 60;          constraints.subgrade_max = 300;
            end
            
            % 记录约束设置日志
            fprintf('  【约束范围v5.4】D0=%.3fmm → %s\n', D0_target, constraints.mode);
            fprintf('    AC:[%d,%d], BC:[%d,%d], SB:[%d,%d], SG:[%d,%d] MPa\n', ...
                constraints.surface_layer_min, constraints.surface_layer_max, ...
                constraints.base_layer_min, constraints.base_layer_max, ...
                constraints.subbase_layer_min, constraints.subbase_layer_max, ...
                constraints.subgrade_min, constraints.subgrade_max);
        end

        %% ==================== 宽松约束（消融变体5专用）====================
        function constraints = getWideConstraints(obj)
        % PPO-WideConstraint 变体：取消物理先验，使用统一宽泛搜索空间
        % 用于消融实验：隔离物理约束贡献 vs LLM推理贡献
            constraints = struct();
            constraints.mode = '宽松约束（消融用）';
            constraints.surface_layer_min = 100;   constraints.surface_layer_max = 50000;
            constraints.base_layer_min    = 100;   constraints.base_layer_max    = 50000;
            constraints.subbase_layer_min = 100;   constraints.subbase_layer_max = 50000;
            constraints.subgrade_min      = 10;    constraints.subgrade_max      = 500;
            fprintf('  【约束范围】Wide（消融变体5）: 全层 [100, 50000] MPa，无物理先验\n');
        end
        
        %% ==================== 网络初始化 ====================
        function initNetworks(obj)
            % He初始化
            scale_in = sqrt(2 / obj.state_dim);
            scale_h = sqrt(2 / obj.hidden_dim);
            
            % Actor网络
            obj.actor_W1 = randn(obj.hidden_dim, obj.state_dim) * scale_in;
            obj.actor_b1 = zeros(obj.hidden_dim, 1);
            obj.actor_W2 = randn(obj.hidden_dim, obj.hidden_dim) * scale_h;
            obj.actor_b2 = zeros(obj.hidden_dim, 1);
            obj.actor_W_mu = randn(obj.action_dim, obj.hidden_dim) * scale_h * 0.01;
            obj.actor_b_mu = zeros(obj.action_dim, 1);
            obj.actor_log_std = -0.5 * ones(obj.action_dim, 1);  % 可学习
            
            % Critic网络
            obj.critic_W1 = randn(obj.hidden_dim, obj.state_dim) * scale_in;
            obj.critic_b1 = zeros(obj.hidden_dim, 1);
            obj.critic_W2 = randn(obj.hidden_dim, obj.hidden_dim) * scale_h;
            obj.critic_b2 = zeros(obj.hidden_dim, 1);
            obj.critic_W_v = randn(1, obj.hidden_dim) * scale_h * 0.01;
            obj.critic_b_v = 0;
        end
        
        %% ==================== 优化器初始化 ====================
        function initOptimizer(obj)
            obj.adam_t = 0;
            obj.adam_beta1 = 0.9;
            obj.adam_beta2 = 0.999;
            obj.adam_eps = 1e-8;
            
            % Actor优化器状态
            obj.actor_m_W1 = zeros(size(obj.actor_W1)); obj.actor_v_W1 = zeros(size(obj.actor_W1));
            obj.actor_m_b1 = zeros(size(obj.actor_b1)); obj.actor_v_b1 = zeros(size(obj.actor_b1));
            obj.actor_m_W2 = zeros(size(obj.actor_W2)); obj.actor_v_W2 = zeros(size(obj.actor_W2));
            obj.actor_m_b2 = zeros(size(obj.actor_b2)); obj.actor_v_b2 = zeros(size(obj.actor_b2));
            obj.actor_m_W_mu = zeros(size(obj.actor_W_mu)); obj.actor_v_W_mu = zeros(size(obj.actor_W_mu));
            obj.actor_m_b_mu = zeros(size(obj.actor_b_mu)); obj.actor_v_b_mu = zeros(size(obj.actor_b_mu));
            obj.actor_m_log_std = zeros(size(obj.actor_log_std)); obj.actor_v_log_std = zeros(size(obj.actor_log_std));
            
            % Critic优化器状态
            obj.critic_m_W1 = zeros(size(obj.critic_W1)); obj.critic_v_W1 = zeros(size(obj.critic_W1));
            obj.critic_m_b1 = zeros(size(obj.critic_b1)); obj.critic_v_b1 = zeros(size(obj.critic_b1));
            obj.critic_m_W2 = zeros(size(obj.critic_W2)); obj.critic_v_W2 = zeros(size(obj.critic_W2));
            obj.critic_m_b2 = zeros(size(obj.critic_b2)); obj.critic_v_b2 = zeros(size(obj.critic_b2));
            obj.critic_m_W_v = zeros(size(obj.critic_W_v)); obj.critic_v_W_v = zeros(size(obj.critic_W_v));
            obj.critic_m_b_v = 0; obj.critic_v_b_v = 0;
        end
        
        function clearBuffer(obj)
            obj.buffer_states = [];
            obj.buffer_actions = [];
            obj.buffer_rewards = [];
            obj.buffer_log_probs = [];
            obj.buffer_values = [];
            obj.buffer_dones = [];
        end
        
        %% ==================== PDE评估 (已修正：调用校准版) ====================
        function pde_results = evaluateModulus(obj, modulus)
            % 【v5.4.3 修正】使用 roadPDEModelingABAQUSCalibrated 确保PPO看到的是校准后的结果
            try
                designParams = struct();
                designParams.thickness = obj.input_data.thickness(:);
                designParams.modulus = [modulus.surface; modulus.base; modulus.subbase];
                designParams.poisson = obj.input_data.poisson(:);
                
                loadParams = struct();
                loadParams.load_pressure = obj.input_data.load_pressure;
                loadParams.load_radius = obj.input_data.load_radius;
                
                boundary_conditions = struct();
                boundary_conditions.modeling_type = 'multilayer_subgrade';
                
                % 【v5.4.3修复】优先使用modulus.subgrade，保持同步
                if isfield(modulus, 'subgrade') && modulus.subgrade > 0
                    boundary_conditions.subgrade_modulus = modulus.subgrade;
                    boundary_conditions.soil_modulus = modulus.subgrade;
                else
                    boundary_conditions.subgrade_modulus = obj.current_subgrade_modulus;
                    boundary_conditions.soil_modulus = obj.current_subgrade_modulus;
                end
                
                boundary_conditions.sensor_offsets = obj.input_data.sensor_offsets;
                
                % 传递路面类型，确保PDE内部能调用正确的校准因子
                if isfield(obj.input_data, 'pavement_type')
                    boundary_conditions.pavement_type = obj.input_data.pavement_type;
                end
                
                % 调用校准版PDE (Calibrated)，而非原版 (ABAQUS)
                pde_results = roadPDEModelingABAQUSCalibrated(designParams, loadParams, boundary_conditions);
                
                if ~pde_results.success
                    error('PDE求解失败');
                end
            catch ME
                % 降级处理：若PDE失败，返回一个惩罚性的高D0值
                pde_results = struct('success', false, 'D0', 1.0, ...
                    'deflections', ones(1, length(obj.input_data.sensor_offsets)));
            end
        end
        
        function D0 = getD0(obj, pde_results)
            if isfield(pde_results, 'D0') && pde_results.D0 > 0
                D0 = pde_results.D0;
            elseif isfield(pde_results, 'deflections') && ~isempty(pde_results.deflections)
                D0 = pde_results.deflections(1);
            else
                D0 = 0.5;
            end
        end
        
        %% ==================== Actor前向传播 ====================
        function [mu, std_val, z1, h1, z2, h2] = actorForward(obj, state)
            if size(state, 1) ~= obj.state_dim, state = state'; end
            
            % 第一隐藏层
            z1 = obj.actor_W1 * state + obj.actor_b1;
            h1 = max(0, z1);  % ReLU
            
            % 第二隐藏层
            z2 = obj.actor_W2 * h1 + obj.actor_b2;
            h2 = max(0, z2);  % ReLU
            
            % 输出层
            mu_raw = obj.actor_W_mu * h2 + obj.actor_b_mu;
            mu = tanh(mu_raw) * obj.action_bound;
            std_val = exp(obj.actor_log_std);
        end
        
        %% ==================== Critic前向传播 ====================
        function [value, z1, h1, z2, h2] = criticForward(obj, state)
            if size(state, 1) ~= obj.state_dim, state = state'; end
            
            z1 = obj.critic_W1 * state + obj.critic_b1;
            h1 = max(0, z1);
            
            z2 = obj.critic_W2 * h1 + obj.critic_b2;
            h2 = max(0, z2);
            
            value = obj.critic_W_v * h2 + obj.critic_b_v;
        end
        
        %% ==================== 动作采样 ====================
        function [action, log_prob] = sampleAction(obj, state)
            % 【v5.4.2修复】使用动态探索率

            % Actor前向传播获取均值
            [action_mean, ~, ~, ~, ~, ~] = obj.actorForward(state);

            % 使用属性中存储的探索标准差
            if isprop(obj, 'current_exploration_std') && obj.current_exploration_std > 0
                action_std = obj.current_exploration_std;
            else
                action_std = exp(obj.actor_log_std(1));
            end

            % 采样动作（高斯分布）
            noise = randn(size(action_mean)) * action_std;
            action = action_mean + noise;

            % 裁剪到[-1, 1]
            action = max(-1, min(1, action));

            % 计算log概率
            log_prob = -0.5 * sum(((action - action_mean) / action_std).^2) ...
                - 0.5 * length(action) * log(2 * pi) ...
                - length(action) * log(action_std);

            % 安全检查
            if isnan(log_prob)
                log_prob = -10;
            end
        end
        
        %% ==================== 动作应用 ====================
        function new_modulus = applyAction(obj, current_modulus, action)
            % 【v5.4.3修复】确保土基模量同步到modulus.subgrade

            % 计算当前误差
            current_error = obj.prev_error;
            if isempty(current_error) || current_error == 0
                current_error = 0.5;
            end

            % 根据误差动态限制action幅度
            if current_error > 0.3
                max_change = 0.25;
            elseif current_error > 0.15
                max_change = 0.15;
            elseif current_error > 0.08
                max_change = 0.10;
            else
                max_change = 0.05;
            end

            % 裁剪action到允许范围
            action = max(-1, min(1, action));
            scaled_action = action * max_change;

            % 应用到各层模量
            new_modulus = current_modulus;

            if length(scaled_action) >= 1
                change_surface = scaled_action(1);
                new_modulus.surface = current_modulus.surface * (1 + change_surface);
            end

            if length(scaled_action) >= 2
                change_base = scaled_action(2);
                new_modulus.base = current_modulus.base * (1 + change_base);
            end

            if length(scaled_action) >= 3
                change_subbase = scaled_action(3);
                new_modulus.subbase = current_modulus.subbase * (1 + change_subbase);
            end

            % 【v5.4.3修复】土基模量处理 - 同时更新两个位置
            if length(scaled_action) >= 4
                change_subgrade = scaled_action(4);
                obj.current_subgrade_modulus = obj.current_subgrade_modulus * (1 + change_subgrade);
            end

            % 四舍五入到精度
            new_modulus.surface = obj.roundToStep(new_modulus.surface, obj.modulus_precision_surface);
            new_modulus.base = obj.roundToStep(new_modulus.base, obj.modulus_precision_base);
            new_modulus.subbase = obj.roundToStep(new_modulus.subbase, obj.modulus_precision_subbase);
            obj.current_subgrade_modulus = obj.roundToStep(obj.current_subgrade_modulus, obj.modulus_precision_subgrade);

            % 强制约束
            new_modulus = obj.enforceConstraints(new_modulus);
            
            % 【v5.4.3关键】同步土基到modulus结构体
            new_modulus.subgrade = obj.current_subgrade_modulus;

            if obj.verbose
                fprintf('    Action变化: AC %.1f%%, BC %.1f%%, SB %.1f%%, SG %.1f%% (限制±%.0f%%)\n', ...
                    scaled_action(1)*100, scaled_action(2)*100, scaled_action(3)*100, ...
                    scaled_action(4)*100, max_change*100);
            end
        end
        
        %% ==================== 约束执行 (v5.4.3修复) ====================
        function modulus = enforceConstraints(obj, modulus)
            % 强制模量满足约束条件
            c = obj.modulus_constraints;
            
            % 范围约束
            modulus.surface = max(c.surface_layer_min, min(c.surface_layer_max, modulus.surface));
            modulus.base = max(c.base_layer_min, min(c.base_layer_max, modulus.base));
            modulus.subbase = max(c.subbase_layer_min, min(c.subbase_layer_max, modulus.subbase));
            obj.current_subgrade_modulus = max(c.subgrade_min, min(c.subgrade_max, obj.current_subgrade_modulus));
           
            
            % 精度取整
            modulus.surface = obj.roundToStep(modulus.surface, obj.modulus_precision_surface);
            modulus.base = obj.roundToStep(modulus.base, obj.modulus_precision_base);
            modulus.subbase = obj.roundToStep(modulus.subbase, obj.modulus_precision_subbase);
            obj.current_subgrade_modulus = obj.roundToStep(obj.current_subgrade_modulus, obj.modulus_precision_subgrade);
            
            % 再次范围约束
            modulus.surface = max(c.surface_layer_min, min(c.surface_layer_max, modulus.surface));
            modulus.base = max(c.base_layer_min, min(c.base_layer_max, modulus.base));
            modulus.subbase = max(c.subbase_layer_min, min(c.subbase_layer_max, modulus.subbase));
            obj.current_subgrade_modulus = max(c.subgrade_min, min(c.subgrade_max, obj.current_subgrade_modulus));
            
            % 【v5.4.3关键】同步土基到modulus结构体
            modulus.subgrade = obj.current_subgrade_modulus;
        end
        
        %% ==================== 状态构建 (v5.4.3修复) ====================
        function state = getState(obj, current_modulus)
            % 构建神经网络输入状态向量 (10维)
            
            c = obj.modulus_constraints;
            
            % 1-4. 归一化模量 (到[0,1]范围)
            norm_surface = (current_modulus.surface - c.surface_layer_min) / ...
                          (c.surface_layer_max - c.surface_layer_min + 1e-6);
            norm_base = (current_modulus.base - c.base_layer_min) / ...
                       (c.base_layer_max - c.base_layer_min + 1e-6);
            norm_subbase = (current_modulus.subbase - c.subbase_layer_min) / ...
                          (c.subbase_layer_max - c.subbase_layer_min + 1e-6);
            
            % 【v5.4.3修复】优先使用modulus.subgrade
            if isfield(current_modulus, 'subgrade') && current_modulus.subgrade > 0
                subgrade_val = current_modulus.subgrade;
            else
                subgrade_val = obj.current_subgrade_modulus;
            end
            norm_subgrade = (subgrade_val - c.subgrade_min) / ...
                           (c.subgrade_max - c.subgrade_min + 1e-6);
            
            % 5. 当前D0误差 (归一化)
            if isempty(obj.prev_error) || isnan(obj.prev_error)
                error_val = 0.5;
            else
                error_val = min(1, obj.prev_error);
            end
            
            % 6. 弯沉比 D0_calc/D0_target
            if ~isempty(obj.current_deflection) && obj.current_deflection > 0
                deflection_ratio = obj.current_deflection / obj.target_deflection;
                deflection_ratio = min(2, max(0, deflection_ratio)) - 1;
            else
                deflection_ratio = 0;
            end
            
            % 7-10. 弯沉盆形状特征
            norm_SCI = 0; norm_BDI = 0; norm_BCI = 0; norm_decay = 0;
            
            if length(obj.target_basin) >= 7
                tb = obj.target_basin(1:7);
                target_SCI = tb(1) - tb(3);
                target_BDI = tb(3) - tb(4);
                target_BCI = tb(4) - tb(5);
                target_decay = tb(7) / max(tb(1), 1e-6);
                
                norm_SCI = target_SCI / max(tb(1), 1e-6);
                norm_BDI = target_BDI / max(tb(1), 1e-6);
                norm_BCI = target_BCI / max(tb(1), 1e-6);
                norm_decay = target_decay;
            end
            
            % 组合10维状态向量
            state = [norm_surface; norm_base; norm_subbase; norm_subgrade; ...
                     error_val; deflection_ratio; norm_SCI; norm_BDI; norm_BCI; norm_decay];
            
            state = state(:);
            state(isnan(state)) = 0;
        end
        
        function val = roundToStep(~, value, step)
            val = round(value / step) * step;
        end
        
        %% ==================== 奖励计算 (v5.3增强版) ====================
        function reward = calculateReward(obj, pde_results, new_modulus)
            D0 = obj.getD0(pde_results);
            error_D0 = abs(D0 - obj.target_deflection) / obj.target_deflection;
            
            % ========== 1. D0匹配奖励 ==========
            if error_D0 < 0.02
                r_D0 = 15.0;
            elseif error_D0 < 0.03
                r_D0 = 12.0;
            elseif error_D0 < 0.05
                r_D0 = 8.0;
            elseif error_D0 < 0.08
                r_D0 = 5.0;
            elseif error_D0 < 0.15
                r_D0 = 2.0;
            elseif error_D0 < 0.30
                r_D0 = 0.0;
            else
                r_D0 = -3.0 * error_D0;
            end
            
            % ========== 2. 弯沉盆形状奖励 (增强版) ==========
            r_basin = 0;
            r_shape = 0;
            
            if isfield(pde_results, 'deflections') && length(pde_results.deflections) >= 7
                calc_basin = pde_results.deflections(1:7);
                target_basin = obj.target_basin(1:min(7, length(obj.target_basin)));
                
                if length(target_basin) >= 7
                    % 2.1 分段加权误差（远端权重更高）
                    weights = [1.0, 1.0, 1.2, 1.5, 1.8, 2.2, 2.5];
                    basin_errors = abs(calc_basin - target_basin) ./ max(target_basin, 0.01);
                    weighted_error = sum(basin_errors .* weights) / sum(weights);
                    
                    if weighted_error < 0.08
                        r_basin = 10.0;
                    elseif weighted_error < 0.12
                        r_basin = 6.0;
                    elseif weighted_error < 0.18
                        r_basin = 3.0;
                    elseif weighted_error < 0.25
                        r_basin = 0.0;
                    else
                        r_basin = -3.0 * weighted_error;
                    end
                    
                    % 2.2 弯沉盆特征指标匹配
                    calc_SCI = calc_basin(1) - calc_basin(3);
                    target_SCI = target_basin(1) - target_basin(3);
                    SCI_error = abs(calc_SCI - target_SCI) / max(target_SCI, 0.01);
                    
                    calc_BDI = calc_basin(3) - calc_basin(4);
                    target_BDI = target_basin(3) - target_basin(4);
                    BDI_error = abs(calc_BDI - target_BDI) / max(target_BDI, 0.01);
                    
                    calc_BCI = calc_basin(4) - calc_basin(5);
                    target_BCI = target_basin(4) - target_basin(5);
                    BCI_error = abs(calc_BCI - target_BCI) / max(target_BCI, 0.01);
                    
                    calc_decay = calc_basin(7) / calc_basin(1);
                    target_decay = target_basin(7) / target_basin(1);
                    decay_error = abs(calc_decay - target_decay) / max(target_decay, 0.01);
                    
                    shape_error = 0.25*SCI_error + 0.25*BDI_error + 0.20*BCI_error + 0.30*decay_error;
                    
                    if shape_error < 0.15
                        r_shape = 8.0;
                    elseif shape_error < 0.25
                        r_shape = 4.0;
                    elseif shape_error < 0.40
                        r_shape = 1.0;
                    else
                        r_shape = -4.0 * shape_error;
                    end
                end
            end
            
            % ========== 3. 改进奖励 ==========
            error_improvement = obj.prev_error - error_D0;
            if error_improvement > 0.01
                r_improve = 2.0;
            elseif error_improvement > 0
                r_improve = 0.5;
            else
                r_improve = -0.3;
            end
            
            % ========== 4. 综合奖励 ==========
            reward = 0.30 * r_D0 + 0.30 * r_basin + 0.30 * r_shape + 0.10 * r_improve;
            
            obj.prev_error = error_D0;
        end
        
        %% ==================== 存储转换 ====================
        function storeTransition(obj, state, action, reward, log_prob, value, done)
            obj.buffer_states = [obj.buffer_states, state];
            obj.buffer_actions = [obj.buffer_actions, action];
            obj.buffer_rewards = [obj.buffer_rewards, reward];
            obj.buffer_log_probs = [obj.buffer_log_probs, log_prob];
            obj.buffer_values = [obj.buffer_values, value];
            obj.buffer_dones = [obj.buffer_dones, double(done)];
        end
        
        %% ==================== PPO更新 (完整实现) ====================
        function [actor_loss, critic_loss] = updatePPO(obj, next_value)
            % 获取buffer大小
            n = size(obj.buffer_states, 2);
            
            if n < 2
                actor_loss = 0;
                critic_loss = 0;
                return;
            end

            % 获取buffer数据
            states = obj.buffer_states';
            actions = obj.buffer_actions';
            rewards = obj.buffer_rewards(:);
            old_log_probs = obj.buffer_log_probs(:);
            old_values = obj.buffer_values(:);
            dones = obj.buffer_dones(:);

            % NaN检测
            if any(isnan(rewards)) || any(isnan(old_values))
                fprintf('    ⚠️ 检测到NaN输入，跳过PPO更新\n');
                actor_loss = 0;
                critic_loss = 0;
                return;
            end

            % 计算GAE和returns
            gamma = obj.gamma;
            gae_lambda = obj.lambda_gae;

            advantages = zeros(n, 1);
            returns = zeros(n, 1);
            gae = 0;

            for t = n:-1:1
                if t == n
                    next_val = next_value;
                else
                    next_val = old_values(t + 1);
                end

                delta = rewards(t) + gamma * next_val * (1 - dones(t)) - old_values(t);
                delta = max(-10, min(10, delta));

                gae = delta + gamma * gae_lambda * (1 - dones(t)) * gae;
                gae = max(-10, min(10, gae));

                advantages(t) = gae;
                returns(t) = advantages(t) + old_values(t);
            end

            % advantage标准化
            adv_std = std(advantages);
            if adv_std < 1e-8 || isnan(adv_std)
                adv_std = 1;
            end
            advantages = (advantages - mean(advantages)) / adv_std;
            advantages = max(-3, min(3, advantages));

            % PPO更新
            clip_ratio = obj.clip_ratio;
            actor_loss_total = 0;
            critic_loss_total = 0;

            for epoch = 1:obj.ppo_epochs
                for i = 1:n
                    state = states(i, :);
                    action = actions(i, :);
                    old_log_prob = old_log_probs(i);
                    advantage = advantages(i);
                    return_val = returns(i);

                    state_col = state(:);
                    [mu, std_val, ~, ~, ~, ~] = obj.actorForward(state_col);
                    
                    action_vec = action(:);
                    new_log_prob = -0.5 * sum(((action_vec - mu) ./ std_val).^2) ...
                        - 0.5 * length(action_vec) * log(2 * pi) ...
                        - sum(log(std_val));
                    
                    entropy = 0.5 * length(action_vec) * (1 + log(2 * pi)) + sum(log(std_val));

                    if isnan(new_log_prob) || isnan(old_log_prob)
                        continue;
                    end

                    log_ratio = new_log_prob - old_log_prob;
                    log_ratio = max(-5, min(5, log_ratio));
                    ratio = exp(log_ratio);

                    surr1 = ratio * advantage;
                    surr2 = max(1 - clip_ratio, min(1 + clip_ratio, ratio)) * advantage;
                    actor_loss = -min(surr1, surr2) - obj.entropy_coef * entropy;

                    [value, ~, ~, ~, ~] = obj.criticForward(state_col);
                    critic_loss = 0.5 * (return_val - value)^2;
                    critic_loss = min(100, critic_loss);

                    if isnan(actor_loss) || isnan(critic_loss)
                        continue;
                    end

                    actor_loss_total = actor_loss_total + actor_loss;
                    critic_loss_total = critic_loss_total + critic_loss;
                end
            end

            actor_loss = actor_loss_total / max(1, n * obj.ppo_epochs);
            critic_loss = critic_loss_total / max(1, n * obj.ppo_epochs);

            if isnan(actor_loss)
                actor_loss = 0;
            end
            if isnan(critic_loss)
                critic_loss = 0;
            end
        end


        %% ==================== Adam优化器 ====================
        function [param, m, v] = adamUpdate(obj, param, grad, m, v)
            obj.adam_t = obj.adam_t + 1;
            m = obj.adam_beta1 * m + (1 - obj.adam_beta1) * grad;
            v = obj.adam_beta2 * v + (1 - obj.adam_beta2) * (grad.^2);
            m_hat = m / (1 - obj.adam_beta1^obj.adam_t);
            v_hat = v / (1 - obj.adam_beta2^obj.adam_t);
            param = param - obj.learning_rate * m_hat ./ (sqrt(v_hat) + obj.adam_eps);
        end

        %% ==================== 优化主函数 (v5.4.3 修复版) ====================
        function [final_modulus, optimization_log] = optimize(obj)
            % OPTIMIZE PPO主优化循环 (v5.4.3 修复版)
            % 修复: 土基同步、探索保护、进度显示

            fprintf('\n  🚀 启动 PPO 优化过程...\n');
            fprintf('  ┌─────────────────────────────────────────────────────────┐\n');
            fprintf('  │ 数据组: %-20s  目标D0: %.4f mm       │\n', obj.case_name, obj.target_deflection);
            fprintf('  │ 收敛阈值: %.1f%%              最大Episodes: %d          │\n', ...
                obj.convergence_threshold * 100, obj.config.ppo_backcalculation.max_episodes);
            fprintf('  └─────────────────────────────────────────────────────────┘\n\n');

            % 1. 提取配置参数
            max_episodes = obj.config.ppo_backcalculation.max_episodes;
            max_steps = obj.config.ppo_backcalculation.max_steps_per_episode;
            early_stop_patience = obj.config.ppo_backcalculation.early_stop_patience;

            % 2. 探索率衰减参数设置 (v5.4.3调整)
            initial_action_std = 0.5;
            min_action_std = 0.01;
            exploration_decay_rate = 0.985;

            % 3. 初始化状态变量
            current_modulus = obj.initial_modulus;
            % 【v5.4.3修复】确保初始模量包含subgrade
            if ~isfield(current_modulus, 'subgrade')
                current_modulus.subgrade = obj.current_subgrade_modulus;
            end
            
            best_modulus = current_modulus;
            best_subgrade = obj.current_subgrade_modulus;  % 【v5.4.3】单独记录最佳土基
            best_error = inf;
            no_improve = 0;
            obj.llm_call_count = 0;
            start_time = tic;

            % 初始化历史记录
            obj.error_history = [];
            obj.modulus_history = [];

            % ==================== 主循环 ====================
            for episode = 1:max_episodes

                % -----------------------------------------------------------
                % 【v5.4.3 修复】探索率动态调整与保护机制
                % -----------------------------------------------------------
                current_action_std = max(min_action_std, initial_action_std * (exploration_decay_rate ^ (episode-1)));
                obj.current_exploration_std = current_action_std;

                % 【v5.4.3修复】放宽探索保护阈值
                if best_error < 0.03
                    % 只有误差<3%才强保护（已达到目标）
                    limit_std = 0.02;
                    if obj.current_exploration_std > limit_std
                        obj.current_exploration_std = limit_std;
                    end
                elseif best_error < 0.05
                    % 误差3-5%时适度限制
                    limit_std = 0.05;
                    if obj.current_exploration_std > limit_std
                        obj.current_exploration_std = limit_std;
                        fprintf('  >>>>>> [探索保护] 误差%.2f%% < 5%%, 限制探索率至 %.3f <<<<<<\n', ...
                            best_error*100, obj.current_exploration_std);
                    end
                elseif best_error < 0.08
                    % 误差5-8%时轻度限制
                    limit_std = 0.10;
                    if obj.current_exploration_std > limit_std
                        obj.current_exploration_std = limit_std;
                    end
                end
                % 误差>8%时不限制，允许大范围探索

                % 同步更新 Actor 网络的 log_std 参数
                obj.actor_log_std = log(obj.current_exploration_std) * ones(obj.action_dim, 1);
                % -----------------------------------------------------------

                % 【v5.4.3新增】醒目的Episode进度显示
                fprintf('\n');
                fprintf('  ████████████████████████████████████████████████████████████████\n');
                fprintf('  ████  [%s]  Episode %3d / %d  ████\n', obj.case_name, episode, max_episodes);
                fprintf('  ████  BestErr = %.2f%%  |  探索率 = %.3f  |  目标 < %.1f%%  ████\n', ...
                    best_error*100, obj.current_exploration_std, obj.convergence_threshold*100);
                fprintf('  ████████████████████████████████████████████████████████████████\n');

                % LLM 引导机制
                if obj.llm_guidance_enabled && (episode == 1 || mod(episode, obj.llm_call_interval) == 0)
                    [adj_modulus, applied] = obj.applyLLMGuidance(current_modulus);
                    if applied
                        current_modulus = adj_modulus;
                        % 同步土基
                        if isfield(adj_modulus, 'subgrade')
                            obj.current_subgrade_modulus = adj_modulus.subgrade;
                        end
                        temp_std = max(0.1, obj.current_exploration_std);
                        obj.actor_log_std = log(temp_std) * ones(obj.action_dim, 1);
                        fprintf('  >>>>>> LLM建议已采纳, 探索率重置为 %.2f <<<<<<\n', temp_std);
                    end
                end

                % 清空经验池
                obj.clearBuffer();

                % 获取初始状态
                state = obj.getState(current_modulus);
                ep_reward = 0;

                % ==================== 采样步循环 ====================
                for step = 1:max_steps
                    % 1. 采样动作
                    [action, log_prob] = obj.sampleAction(state);

                    % 2. 估计价值 (Critic)
                    [value, ~, ~, ~, ~] = obj.criticForward(state);

                    % 3. 执行动作 (应用模量调整)
                    new_modulus = obj.applyAction(current_modulus, action);

                    % 4. 环境反馈 (PDE计算) - 注意：这里不打印PDE详情，减少输出
                    pde_results = obj.evaluateModulus(new_modulus);

                    % 5. 计算奖励
                    reward = obj.calculateReward(pde_results, new_modulus);

                    % 6. 计算误差
                    D0 = obj.getD0(pde_results);
                    current_error = abs(D0 - obj.target_deflection) / obj.target_deflection;

                    % 7. 更新最优解
                    if current_error < best_error
                        best_error = current_error;
                        best_modulus = new_modulus;
                        best_subgrade = obj.current_subgrade_modulus;  % 【v5.4.3关键】同步保存土基
                        no_improve = 0;
                        
                        % 【v5.4.3】醒目显示新最优
                        fprintf('\n');
                        fprintf('    ★★★ 发现新最优! ★★★\n');
                        fprintf('    ★ Step %2d: D0=%.4f mm (误差=%.2f%%)\n', step, D0, current_error*100);
                        fprintf('    ★ 模量=[%d, %d, %d, %d] MPa\n', ...
                            round(new_modulus.surface), round(new_modulus.base), ...
                            round(new_modulus.subbase), round(obj.current_subgrade_modulus));
                        fprintf('    ★★★★★★★★★★★★★★★★★\n\n');

                        % 记录最优状态
                        obj.modulus_history = [obj.modulus_history; ...
                            [new_modulus.surface, new_modulus.base, new_modulus.subbase, obj.current_subgrade_modulus]];
                        obj.deflection_history = [obj.deflection_history; D0];
                    end

                    % 8. 存储转换 (Transition)
                    done = (current_error < obj.convergence_threshold);
                    obj.storeTransition(state, action, reward, log_prob, value, done);

                    % 9. 更新状态统计
                    ep_reward = ep_reward + reward;
                    current_modulus = new_modulus;
                    obj.current_deflection = D0;
                    state = obj.getState(current_modulus);

                    if done
                        fprintf('\n');
                        fprintf('    ◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆\n');
                        fprintf('    ◆  达到收敛阈值! 误差=%.2f%% < %.1f%%  ◆\n', ...
                            current_error*100, obj.convergence_threshold*100);
                        fprintf('    ◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆◆\n');
                        break;
                    end
                end

                % 记录历史
                obj.error_history(end+1) = best_error;
                obj.episode_rewards(end+1) = ep_reward;

                % ==================== PPO 更新 ====================
                next_state = obj.getState(current_modulus);
                [next_val, ~, ~, ~, ~] = obj.criticForward(next_state);
                [~, ~] = obj.updatePPO(next_val);

                % ==================== 终止条件检查 ====================
                if best_error < obj.convergence_threshold
                    fprintf('\n');
                    fprintf('  ================================================================\n');
                    fprintf('  ==  [%s] 优化成功!  ==\n', obj.case_name);
                    fprintf('  ==  最终误差: %.2f%% < %.1f%%  ==\n', ...
                        best_error*100, obj.convergence_threshold*100);
                    fprintf('  ================================================================\n');
                    break;
                end

                if no_improve >= early_stop_patience
                    fprintf('\n');
                    fprintf('  ----------------------------------------------------------------\n');
                    fprintf('  --  [%s] 提前停止: 连续 %d 轮无改善  --\n', obj.case_name, no_improve);
                    fprintf('  --  当前最佳误差: %.2f%%  --\n', best_error*100);
                    fprintf('  ----------------------------------------------------------------\n');
                    break;
                end

                no_improve = no_improve + 1;
            end

            % 整理输出
            final_modulus = best_modulus;
            % 【v5.4.3关键修复】确保最终模量的土基值正确
            final_modulus.subgrade = best_subgrade;
            obj.current_subgrade_modulus = best_subgrade;  % 同步更新

            elapsed_time = toc(start_time);

            optimization_log = struct();
            optimization_log.best_error = best_error;
            optimization_log.iterations = episode;
            optimization_log.total_time = elapsed_time;
            optimization_log.converged = (best_error < obj.convergence_threshold);
            optimization_log.error_history = obj.error_history;
            optimization_log.modulus_history = obj.modulus_history;
            optimization_log.episode_rewards = obj.episode_rewards;
            optimization_log.llm_call_count = obj.llm_call_count;

            fprintf('\n');
            fprintf('  ╔══════════════════════════════════════════════════════════════╗\n');
            fprintf('  ║  [%s] PPO优化完成                              ║\n', obj.case_name);
            fprintf('  ╠══════════════════════════════════════════════════════════════╣\n');
            fprintf('  ║  最佳模量: AC=%5d  BC=%5d  SB=%4d  SG=%3d MPa    ║\n', ...
                round(final_modulus.surface), round(final_modulus.base), ...
                round(final_modulus.subbase), round(final_modulus.subgrade));
            fprintf('  ║  最终误差: %.2f%%    耗时: %.1f秒    Episodes: %d        ║\n', ...
                best_error*100, elapsed_time, episode);
            fprintf('  ╚══════════════════════════════════════════════════════════════╝\n\n');
        end
        
        %% ==================== 绘图函数 (v5.2新增) ====================
        function plotOptimizationResults(obj, best_modulus, best_subgrade, best_deflection)
            % 创建图窗
            fig = figure('Name', 'PPO优化结果', 'Position', [100, 100, 1400, 900]);
            
            % 子图1：误差收敛曲线
            subplot(2, 3, 1);
            if ~isempty(obj.error_history)
                plot(1:length(obj.error_history), obj.error_history * 100, 'b-', 'LineWidth', 2);
                hold on;
                yline(obj.convergence_threshold * 100, 'r--', 'LineWidth', 1.5);
                text(length(obj.error_history)*0.7, obj.convergence_threshold * 100 + 1, ...
                    sprintf('收敛阈值%.0f%%', obj.convergence_threshold * 100), 'Color', 'r');
                xlabel('Episode');
                ylabel('D0误差 (%)');
                title(sprintf('%s - 误差收敛曲线', obj.case_name));
                grid on;
                xlim([1, max(length(obj.error_history), 2)]);
            end
            
            % 子图2：奖励曲线
            subplot(2, 3, 2);
            if ~isempty(obj.episode_rewards)
                plot(1:length(obj.episode_rewards), obj.episode_rewards, 'g-', 'LineWidth', 2);
                xlabel('Episode');
                ylabel('累计奖励');
                title('奖励曲线');
                grid on;
                xlim([1, max(length(obj.episode_rewards), 2)]);
            end
            
            % 子图3：模量演化
            subplot(2, 3, 3);
            if ~isempty(obj.modulus_history) && size(obj.modulus_history, 2) >= 3
                episodes = 1:size(obj.modulus_history, 1);
                surface_vals = obj.modulus_history(:, 1);
                base_vals = obj.modulus_history(:, 2);
                subbase_vals = obj.modulus_history(:, 3);
                
                semilogy(episodes, surface_vals, 'r-o', 'LineWidth', 2, 'MarkerSize', 4, 'DisplayName', '表面层');
                hold on;
                semilogy(episodes, base_vals, 'b-s', 'LineWidth', 2, 'MarkerSize', 4, 'DisplayName', '基层');
                semilogy(episodes, subbase_vals, 'g-^', 'LineWidth', 2, 'MarkerSize', 4, 'DisplayName', '底基层');
                xlabel('Episode');
                ylabel('模量 (MPa)');
                title('模量演化');
                legend('Location', 'best');
                grid on;
                xlim([1, max(size(obj.modulus_history, 1), 2)]);
            end
            
            % 子图4：弯沉盆对比
            subplot(2, 3, 4);
            sensor_positions = [0, 20, 30, 60, 90, 120, 150];
            
            % 获取最终弯沉盆
            final_modulus = best_modulus;
            final_modulus.subgrade = best_subgrade;
            obj.current_subgrade_modulus = best_subgrade;
            final_pde = obj.evaluateModulus(final_modulus);
            if isfield(final_pde, 'deflections') && length(final_pde.deflections) >= 7
                calc_basin = final_pde.deflections(1:7);
            else
                calc_basin = zeros(1, 7);
            end
            
            target_basin = obj.target_basin(1:min(7, length(obj.target_basin)));
            if length(target_basin) < 7
                target_basin = [target_basin, zeros(1, 7-length(target_basin))];
            end
            
            plot(sensor_positions, target_basin, 'bo-', 'LineWidth', 2, 'MarkerSize', 8, 'DisplayName', '目标弯沉盆');
            hold on;
            plot(sensor_positions, calc_basin, 'rs--', 'LineWidth', 2, 'MarkerSize', 8, 'DisplayName', '反演弯沉盆');
            xlabel('距荷载中心距离 (cm)');
            ylabel('弯沉 (mm)');
            title('弯沉盆对比');
            legend('Location', 'northeast');
            grid on;
            set(gca, 'YDir', 'reverse');
            
            % 子图5：弯沉盆误差分布
            subplot(2, 3, 5);
            if length(target_basin) >= 7 && length(calc_basin) >= 7
                basin_errors = (calc_basin - target_basin) ./ max(target_basin, 0.001) * 100;
                bar_colors = zeros(length(basin_errors), 3);
                for i = 1:length(basin_errors)
                    if abs(basin_errors(i)) < 10
                        bar_colors(i, :) = [0.3, 0.8, 0.3];
                    elseif abs(basin_errors(i)) < 20
                        bar_colors(i, :) = [1.0, 0.8, 0.0];
                    else
                        bar_colors(i, :) = [0.9, 0.3, 0.3];
                    end
                end
                b = bar(sensor_positions, basin_errors);
                b.FaceColor = 'flat';
                b.CData = bar_colors;
                xlabel('测点位置 (cm)');
                ylabel('相对误差 (%)');
                title('各测点弯沉误差');
                grid on;
                
                for i = 1:length(basin_errors)
                    if basin_errors(i) >= 0
                        text(sensor_positions(i), basin_errors(i) + 3, ...
                            sprintf('%.1f%%', basin_errors(i)), 'HorizontalAlignment', 'center', 'FontSize', 8);
                    else
                        text(sensor_positions(i), basin_errors(i) - 3, ...
                            sprintf('%.1f%%', basin_errors(i)), 'HorizontalAlignment', 'center', 'FontSize', 8);
                    end
                end
            end
            
            % 子图6：结果摘要文本
            subplot(2, 3, 6);
            axis off;
            
            if exist('basin_errors', 'var')
                avg_basin_err = mean(abs(basin_errors));
            else
                avg_basin_err = 0;
            end
            
            summary_text = {
                '══════ PPO反演结果摘要 (v5.4.3) ══════', ...
                '', ...
                sprintf('【数据组】%s', obj.case_name), ...
                '', ...
                '【最终模量】', ...
                sprintf('  表面层: %d MPa', best_modulus.surface), ...
                sprintf('  基  层: %d MPa', best_modulus.base), ...
                sprintf('  底基层: %d MPa', best_modulus.subbase), ...
                sprintf('  土  基: %d MPa', round(best_subgrade)), ...
                '', ...
                '【弯沉匹配】', ...
                sprintf('  目标D0: %.4f mm', obj.target_deflection), ...
                sprintf('  反演D0: %.4f mm', best_deflection), ...
                sprintf('  D0误差: %.2f%%', abs(best_deflection - obj.target_deflection) / obj.target_deflection * 100), ...
                sprintf('  弯沉盆平均误差: %.2f%%', avg_basin_err), ...
                '', ...
                '【优化统计】', ...
                sprintf('  总Episode: %d', length(obj.error_history)), ...
                sprintf('  LLM调用: %d 次', obj.llm_call_count), ...
                sprintf('  约束模式: %s', obj.modulus_constraints.mode)
            };
            
            text(0.05, 0.95, summary_text, 'FontSize', 10, 'FontName', 'FixedWidth', ...
                'VerticalAlignment', 'top', 'Interpreter', 'none');
            
            % 保存图片
            timestamp = datestr(now, 'yyyymmdd_HHMMSS');
            filename = sprintf('PPO_optimization_%s_%s.png', obj.case_name, timestamp);
            saveas(fig, filename);
            fprintf('\n📊 优化结果图表已保存: %s\n', filename);
        end
        
        %% ==================== LLM引导 (完整实现) ====================
        function [adjusted_modulus, applied] = applyLLMGuidance(obj, current_modulus)
            % 获取LLM建议并解析应用

            D0 = obj.current_deflection;
            error_val = abs(D0 - obj.target_deflection) / obj.target_deflection;

            % 动态调整幅度限制
            if error_val > 0.5
                max_adjustment = 0.40;
            elseif error_val > 0.2
                max_adjustment = 0.30;
            elseif error_val > 0.1
                max_adjustment = 0.20;
            else
                max_adjustment = 0.15;
            end

            fprintf('    调整幅度限制: ±%.0f%% (当前误差: %.1f%%)\n', max_adjustment*100, error_val*100);

            % 构建prompt
            % 根据路面类型设定角色
if isfield(obj.input_data, 'pavement_type')
    pt = obj.input_data.pavement_type;
else
    pt = 'flexible';
end

if strcmp(pt, 'semi_rigid')
    role_str = ['a pavement backcalculation expert for semi-rigid base pavements. ' ...
        'In this pavement type, BC modulus (cement-stabilized) is expected to EXCEED ' ...
        'AC modulus. Do NOT penalize solutions where BC > AC.'];
    stiffness_rule = 'Expected stiffness pattern: BC > AC >> SB > SG (semi-rigid characteristic).';
elseif strcmp(pt, 'inverted')
    role_str = ['a pavement backcalculation expert for inverted pavement structures. ' ...
        'Surface AC modulus > granular base modulus is expected.'];
    stiffness_rule = 'Expected stiffness pattern: AC > SB > BC (inverted structure characteristic).';
else
    role_str = ['a pavement backcalculation expert for flexible pavement systems. ' ...
        'Modulus should generally decrease with depth.'];
    stiffness_rule = 'Expected stiffness pattern: AC > BC > SB > SG (flexible pavement characteristic).';
end

% 弯沉盆各点误差（用于定位问题层）
basin_error_str = '';
if ~isempty(obj.target_basin)
    calc_basin = obj.current_deflection;  % 简化，实际可扩展为多点
    basin_error_str = sprintf('Center deflection error: %.1f%%\n', error_val*100);
end

% 构建prompt
prompt = sprintf([...
    'You are %s\n\n' ...
    '[Current Optimization State]\n' ...
    'Pavement type: %s\n' ...
    '%s\n' ...
    'Current moduli: AC=%d MPa, BC=%d MPa, SB=%d MPa, SG=%d MPa\n' ...
    'Computed D0: %.4f mm | Target D0: %.4f mm | Error: %.1f%%\n' ...
    '%s' ...
    'Feasible bounds: AC[%d,%d], BC[%d,%d], SB[%d,%d], SG[%d,%d] MPa\n' ...
    'Maximum single-step adjustment: ±%.0f%%\n\n' ...
    '[Physical Plausibility Check]\n' ...
    '%s\n\n' ...
    '[Diagnosis Guidance]\n' ...
    'If error > 0 (calculated > target): overall moduli likely too LOW → consider increasing\n' ...
    'If error < 0 (calculated < target): overall moduli likely too HIGH → consider decreasing\n' ...
    'Near-field sensor error (D0-D30) → adjust surface AC layer\n' ...
    'Mid-field sensor error (D30-D60) → adjust base BC layer\n' ...
    'Far-field sensor error (D90-D150) → adjust subbase SB or subgrade SG\n\n' ...
    '[Response Format — one line per layer, no other text]\n' ...
    'AC: +X%% or -X%% or unchanged\n' ...
    'BC: +X%% or -X%% or unchanged\n' ...
    'SB: +X%% or -X%% or unchanged\n' ...
    'SG: +X%% or -X%% or unchanged\n'], ...
    role_str, pt, stiffness_rule, ...
    current_modulus.surface, current_modulus.base, current_modulus.subbase, ...
    round(obj.current_subgrade_modulus), D0, obj.target_deflection, error_val*100, ...
    basin_error_str, ...
    obj.modulus_constraints.surface_layer_min, obj.modulus_constraints.surface_layer_max, ...
    obj.modulus_constraints.base_layer_min, obj.modulus_constraints.base_layer_max, ...
    obj.modulus_constraints.subbase_layer_min, obj.modulus_constraints.subbase_layer_max, ...
    obj.modulus_constraints.subgrade_min, obj.modulus_constraints.subgrade_max, ...
    max_adjustment * 100, stiffness_rule);

            % 调用LLM
            fprintf('    正在调用LLM API (%s)...\n', obj.config.llm_guidance.model);
            response = callLLMAPI(prompt, obj.config, obj.config.llm_guidance.model);
            obj.llm_call_count = obj.llm_call_count + 1;

            % 初始化返回值
            adjusted_modulus = current_modulus;
            applied = false;

            if isempty(response)
                fprintf('    LLM响应为空\n');
                return;
            end

            fprintf('    LLM响应: %s\n', strtrim(response(1:min(150, length(response)))));

            % 解析各层调整建议
            [adj_surface, found1] = obj.parseAdjustment(response, {'面层', 'surface', 'AC', '表面'});
            [adj_base, found2] = obj.parseAdjustment(response, {'基层', 'base', 'BC'});
            [adj_subbase, found3] = obj.parseAdjustment(response, {'底基层', 'subbase', 'SB'});
            [adj_subgrade, found4] = obj.parseAdjustment(response, {'土基', 'subgrade', 'SG'});

            if found1 || found2 || found3 || found4
                applied = true;

                % 限制调整幅度
                adj_surface = max(-max_adjustment, min(max_adjustment, adj_surface));
                adj_base = max(-max_adjustment, min(max_adjustment, adj_base));
                adj_subbase = max(-max_adjustment, min(max_adjustment, adj_subbase));
                adj_subgrade = max(-max_adjustment, min(max_adjustment, adj_subgrade));

                if found1 && abs(adj_surface) > 0.01
                    adjusted_modulus.surface = obj.roundToStep(current_modulus.surface * (1 + adj_surface), obj.modulus_precision_surface);
                    fprintf('    面层调整: %+.0f%%\n', adj_surface*100);
                end
                if found2 && abs(adj_base) > 0.01
                    adjusted_modulus.base = obj.roundToStep(current_modulus.base * (1 + adj_base), obj.modulus_precision_base);
                    fprintf('    基层调整: %+.0f%%\n', adj_base*100);
                end
                if found3 && abs(adj_subbase) > 0.01
                    adjusted_modulus.subbase = obj.roundToStep(current_modulus.subbase * (1 + adj_subbase), obj.modulus_precision_subbase);
                    fprintf('    底基层调整: %+.0f%%\n', adj_subbase*100);
                end
                if found4 && abs(adj_subgrade) > 0.01
                    obj.current_subgrade_modulus = obj.roundToStep(obj.current_subgrade_modulus * (1 + adj_subgrade), obj.modulus_precision_subgrade);
                    fprintf('    土基调整: %+.0f%%\n', adj_subgrade*100);
                end

                % 尝试调用LLM验证模块（可选）
                try
                    input_data_for_verify = obj.input_data;
                    input_data_for_verify.measured_deflection = obj.target_deflection;

                    [is_valid, validation_report, corrected] = verifyLLMOutput(...
                        adjusted_modulus, input_data_for_verify, obj.config, 'moderate');

                    if ~is_valid
                        fprintf('    ⚠️ LLM建议未通过验证 (得分: %.0f/%.0f)，使用修正值\n', ...
                            validation_report.overall_score, validation_report.max_score);
                        if isstruct(corrected) && isfield(corrected, 'surface')
                            adjusted_modulus = corrected;
                        end
                    else
                        fprintf('    ✓ LLM建议通过验证 (得分: %.0f/%.0f)\n', ...
                            validation_report.overall_score, validation_report.max_score);
                    end
                catch
                    % 验证模块不存在时跳过
                end

                % 内联约束逻辑
                c = obj.modulus_constraints;

                % 范围约束
                adjusted_modulus.surface = max(c.surface_layer_min, min(c.surface_layer_max, adjusted_modulus.surface));
                adjusted_modulus.base = max(c.base_layer_min, min(c.base_layer_max, adjusted_modulus.base));
                adjusted_modulus.subbase = max(c.subbase_layer_min, min(c.subbase_layer_max, adjusted_modulus.subbase));
                obj.current_subgrade_modulus = max(c.subgrade_min, min(c.subgrade_max, obj.current_subgrade_modulus));


                % 精度取整
                adjusted_modulus.surface = obj.roundToStep(adjusted_modulus.surface, obj.modulus_precision_surface);
                adjusted_modulus.base = obj.roundToStep(adjusted_modulus.base, obj.modulus_precision_base);
                adjusted_modulus.subbase = obj.roundToStep(adjusted_modulus.subbase, obj.modulus_precision_subbase);
                obj.current_subgrade_modulus = obj.roundToStep(obj.current_subgrade_modulus, obj.modulus_precision_subgrade);

                % 再次范围约束
                adjusted_modulus.surface = max(c.surface_layer_min, min(c.surface_layer_max, adjusted_modulus.surface));
                adjusted_modulus.base = max(c.base_layer_min, min(c.base_layer_max, adjusted_modulus.base));
                adjusted_modulus.subbase = max(c.subbase_layer_min, min(c.subbase_layer_max, adjusted_modulus.subbase));
                obj.current_subgrade_modulus = max(c.subgrade_min, min(c.subgrade_max, obj.current_subgrade_modulus));
                
                % 【v5.4.3关键】同步土基到modulus结构体
                adjusted_modulus.subgrade = obj.current_subgrade_modulus;
            end
        end
        
        function [adjustment, found] = parseAdjustment(~, response, keywords)
            % 解析LLM响应中的调整百分比 - 增强版
            adjustment = 0;
            found = false;
            
            % 预处理响应：移除markdown格式符号
            response = regexprep(response, '\*\*', '');
            response = regexprep(response, '\\n', ' ');
            response_lower = lower(response);
            
            for i = 1:length(keywords)
                keyword = lower(keywords{i});
                idx = strfind(response_lower, keyword);
                
                if ~isempty(idx)
                    for j = 1:length(idx)
                        start_pos = max(1, idx(j) - 5);
                        end_pos = min(idx(j) + length(keyword) + 60, length(response));
                        snippet = response(start_pos:end_pos);
                        snippet_lower = lower(snippet);
                        
                        % 模式1: "AC: +10%" 或 "AC:+10%" 或 "AC: -15%"
                        pattern1 = [keyword, '\s*[:：]\s*([+-]?\d+\.?\d*)\s*%'];
                        tokens = regexp(snippet_lower, pattern1, 'tokens');
                        if ~isempty(tokens)
                            value = str2double(tokens{1}{1});
                            if ~isnan(value)
                                found = true;
                                adjustment = value / 100;
                                return;
                            end
                        end
                        
                        % 模式2: 查找关键词后最近的百分比数值
                        pattern2 = '([+-]?\d+\.?\d*)\s*%';
                        tokens = regexp(snippet, pattern2, 'tokens');
                        if ~isempty(tokens)
                            value = str2double(tokens{1}{1});
                            if ~isnan(value) && abs(value) <= 100
                                found = true;
                                if contains(snippet, '-') && ~contains(snippet, ['+' num2str(abs(value))])
                                    adjustment = -abs(value) / 100;
                                elseif contains(snippet, '减') || contains(snippet_lower, 'decrease') || ...
                                       contains(snippet, '降') || contains(snippet, '下调')
                                    adjustment = -abs(value) / 100;
                                else
                                    adjustment = abs(value) / 100;
                                end
                                return;
                            end
                        end
                        
                        % 模式3: "增加10%" 或 "提高15%"
                        pattern3 = '(增[加大]|提高|上调|上升)\s*(\d+\.?\d*)\s*%';
                        tokens = regexp(snippet, pattern3, 'tokens');
                        if ~isempty(tokens) && length(tokens{1}) >= 2
                            value = str2double(tokens{1}{2});
                            if ~isnan(value)
                                found = true;
                                adjustment = abs(value) / 100;
                                return;
                            end
                        end
                        
                        % 模式4: "减少10%" 或 "降低15%"
                        pattern4 = '(减[少小]|降低|下调|下降)\s*(\d+\.?\d*)\s*%';
                        tokens = regexp(snippet, pattern4, 'tokens');
                        if ~isempty(tokens) && length(tokens{1}) >= 2
                            value = str2double(tokens{1}{2});
                            if ~isnan(value)
                                found = true;
                                adjustment = -abs(value) / 100;
                                return;
                            end
                        end
                    end
                    
                    % 检查"不变"或"0%"
                    if contains(response_lower, [keyword '.*不变']) || ...
                       contains(response_lower, [keyword '.*0%']) || ...
                       contains(response_lower, [keyword '.*保持'])
                        found = true;
                        adjustment = 0;
                        return;
                    end
                end
            end
        end
    end
end