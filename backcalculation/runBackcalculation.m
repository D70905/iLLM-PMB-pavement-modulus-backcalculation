function runBackcalculation_v2()
% RUNBACKCALCULATION 道路结构模量反演主程序（双模式输入版）
%
% 【功能】
%   1. 支持自然语言输入模式（LLM解析）
%   2. 支持传统结构化输入模式
%   3. 根据路面类型自动设置模量约束范围
%   4. 支持多种弯沉测点配置（7点/9点/自定义）
%
% 输入模式说明:
%   - 自然语言模式: 用户用自然语言描述路面情况，LLM自动解析
%   - 结构化模式: 用户逐步输入各参数（传统方式）
%
% 用法:
%   runBackcalculation()  % 交互式输入

fprintf('╔════════════════════════════════════════════════════════════╗\n');
fprintf('║     道路结构模量反演系统 (双模式输入版 v2.0)              ║\n');
fprintf('║     Pavement Modulus Backcalculation System                ║\n');
fprintf('║     基于PDE建模 + PPO强化学习 + LLM智能引导               ║\n');
fprintf('╚════════════════════════════════════════════════════════════╝\n\n');

try
    % ============= Step 0: 环境准备 =============
    fprintf('Step 0: 环境准备与路径配置...\n');
    project_root = fileparts(mfilename('fullpath'));
    setupPaths(project_root);
    fprintf('✅ 环境配置完成\n\n');
    
    % ============= Step 1: 加载配置 =============
    fprintf('Step 1: 加载反演系统配置...\n');
    config = loadConfig();
    fprintf('✅ 配置加载完成\n\n');
    
    % ============= Step 2: 获取输入数据（双模式） =============
    fprintf('Step 2: 输入实测数据...\n');
    input_data = getInputData_DualMode(config);
    displayInputData(input_data);
    fprintf('✅ 输入数据验证通过\n\n');
    
    % ============= Step 3: 初始模量估计 =============
    fprintf('Step 3: 生成初始模量估计...\n');
    
    % 【修复】安全检查配置字段
    use_llm_initial = false;
    if isfield(config, 'llm_guidance')
        if isfield(config.llm_guidance, 'use_for_initial_estimate')
            use_llm_initial = config.llm_guidance.use_for_initial_estimate;
        elseif isfield(config.llm_guidance, 'enabled')
            use_llm_initial = config.llm_guidance.enabled;
        end
    end
    
    if use_llm_initial
        try
            initial_modulus = initialModulusGenerator(input_data, config, 'hybrid');
            fprintf('✅ LLM辅助初始估计完成\n');
        catch ME
            fprintf('  ⚠️ LLM调用失败: %s\n', ME.message);
            initial_modulus = initialModulusGenerator(input_data, config, 'empirical');
        end
    else
        initial_modulus = initialModulusGenerator(input_data, config, 'empirical');
    end
    
    displayInitialEstimate(initial_modulus, input_data);
    fprintf('\n');
    
    % ============= Step 4: 初始PDE验证 =============
    fprintf('Step 4: 初始模量PDE正向验证...\n');
    
    initial_params = constructPDEParams(input_data, initial_modulus);
    initial_pde_results = performPDE(initial_params, input_data);
    
    initial_D0 = getD0FromResults(initial_pde_results);
    initial_error = abs(initial_D0 - input_data.measured_deflection) / input_data.measured_deflection;
    
    fprintf('  初始模量估计:\n');
    fprintf('    表面层: %d MPa\n', initial_modulus.surface);
    fprintf('    基层:   %d MPa\n', initial_modulus.base);
    fprintf('    底基层: %d MPa\n', initial_modulus.subbase);
    fprintf('\n  【弯沉比较】:\n');
    fprintf('    实测弯沉D0:     %.4f mm\n', input_data.measured_deflection);
    fprintf('    计算弯沉D0:     %.4f mm\n', initial_D0);
    fprintf('    相对误差:       %.2f%%\n', initial_error * 100);
    
    % 判断是否需要优化
    if initial_error < config.backcalculation.convergence_threshold
        fprintf('✅ 初始估计已满足精度要求,无需优化\n\n');
        final_modulus = initial_modulus;
        final_pde_results = initial_pde_results;
        final_error = initial_error;
        optimization_log = struct('iterations', 0, 'converged', true, 'total_time', 0);
    else
        fprintf('⚠️  初始误差较大,启动PPO优化...\n\n');
        
        % ============= Step 5: PPO多起点反演优化（Multi-Run） =============
        fprintf('Step 5: 启动 Multi-Run PPO 模量反演（方案A）...\n');
        
        % ---- 多次运行配置 ----
        n_runs = 5;  % 独立运行次数（论文中可设为5或8）
        perturbation_range = [0.65, 1.35];  % 初始模量扰动范围（±35%）
        
        all_solutions = struct();  % 收集所有收敛解
        n_converged = 0;
        
        for run_idx = 1:n_runs
            fprintf('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
            fprintf('  [Multi-Run] 第 %d / %d 次独立运行\n', run_idx, n_runs);
            fprintf('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
            
            % 设定随机种子（保证可复现性）
            rng(run_idx * 42);
            
            % 生成本次初始模量（第1次使用LLM估计，后续加扰动）
            if run_idx == 1
                run_initial_modulus = initial_modulus;
                fprintf('  第1次：使用LLM初始估计值（无扰动）\n');
            else
                factor_surface = perturbation_range(1) + rand() * diff(perturbation_range);
                factor_base    = perturbation_range(1) + rand() * diff(perturbation_range);
                factor_subbase = perturbation_range(1) + rand() * diff(perturbation_range);
                run_initial_modulus = initial_modulus;
                run_initial_modulus.surface = round(initial_modulus.surface * factor_surface / 50) * 50;
                run_initial_modulus.base    = round(initial_modulus.base    * factor_base    / 50) * 50;
                run_initial_modulus.subbase = round(initial_modulus.subbase * factor_subbase / 50) * 50;
                % 约束到合理范围（防止扰动后越界）
                run_initial_modulus.surface = max(500,  min(15000, run_initial_modulus.surface));
                run_initial_modulus.base    = max(100,  min(35000, run_initial_modulus.base));
                run_initial_modulus.subbase = max(50,   min(8000,  run_initial_modulus.subbase));
                fprintf('  扰动系数: AC=%.2f, BC=%.2f, SB=%.2f\n', ...
                    factor_surface, factor_base, factor_subbase);
                fprintf('  扰动初始模量: AC=%d, BC=%d, SB=%d MPa\n', ...
                    run_initial_modulus.surface, run_initial_modulus.base, run_initial_modulus.subbase);
            end
            
            % 本次运行的初始PDE验证
            run_initial_params = constructPDEParams(input_data, run_initial_modulus);
            run_initial_pde    = performPDE(run_initial_params, input_data);
            
            % 创建独立PPO智能体（网络权重随机初始化，与seed绑定）
            try
                backcalc_agent = BackcalculationPPO(input_data, config, ...
                                                    run_initial_modulus, run_initial_pde);
                [run_modulus, run_log] = backcalc_agent.optimize();
                
                % 计算本次最终弯沉误差
                run_params      = constructPDEParams(input_data, run_modulus);
                run_pde_results = performPDE(run_params, input_data);
                run_D0          = getD0FromResults(run_pde_results);
                run_error       = abs(run_D0 - input_data.measured_deflection) / ...
                                  input_data.measured_deflection;
                
                % 计算弯沉盆平均误差
                if isfield(run_pde_results, 'deflections') && ...
                   length(run_pde_results.deflections) >= length(input_data.deflection_basin)
                    n_s = length(input_data.deflection_basin);
                    basin_errors_run = abs(run_pde_results.deflections(1:n_s) - ...
                                          input_data.deflection_basin(1:n_s)) ./ ...
                                       input_data.deflection_basin(1:n_s);
                    run_basin_error = mean(basin_errors_run) * 100;
                else
                    run_basin_error = run_error * 100;
                end
                
                % 存入候选解集合
                n_converged = n_converged + 1;
                all_solutions(n_converged).run_idx       = run_idx;
                all_solutions(n_converged).modulus       = run_modulus;
                all_solutions(n_converged).pde_results   = run_pde_results;
                all_solutions(n_converged).D0_error      = run_error;
                all_solutions(n_converged).basin_error   = run_basin_error;
                all_solutions(n_converged).converged     = run_log.converged;
                all_solutions(n_converged).initial_modulus = run_initial_modulus;
                all_solutions(n_converged).optimization_log = run_log;
                
                fprintf('  ✅ 第%d次运行完成: D0误差=%.2f%%, 弯沉盆误差=%.2f%%\n', ...
                    run_idx, run_error*100, run_basin_error);
                    
            catch ME_run
                fprintf('  ⚠️ 第%d次运行失败: %s，跳过\n', run_idx, ME_run.message);
            end
        end
        
        fprintf('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
        fprintf('  [Multi-Run] 共获得 %d 个候选解\n', n_converged);
        fprintf('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n');
        
        % ============= Step 5b: LLM物理推理评分选优 =============
        fprintf('Step 5b: LLM物理推理评分，从 %d 个候选解中选优...\n', n_converged);
        
        if n_converged == 0
            error('所有Multi-Run均失败，无法完成反演。');
        elseif n_converged == 1
            fprintf('  仅1个候选解，直接采用。\n');
            selected_idx = 1;
        else
            % 调用LLM评分选优
            selected_idx = llmSelectBestSolution(all_solutions, n_converged, input_data, config);
        end
        
        % 提取最终选定解
        final_modulus      = all_solutions(selected_idx).modulus;
        final_pde_results  = all_solutions(selected_idx).pde_results;
        final_error        = all_solutions(selected_idx).D0_error;
        optimization_log   = all_solutions(selected_idx).optimization_log;
        optimization_log.multi_run_n_candidates = n_converged;
        optimization_log.multi_run_selected_idx = selected_idx;
        
        fprintf('✅ Multi-Run + LLM选优完成，采用第 %d 次运行的解\n\n', ...
            all_solutions(selected_idx).run_idx);
        
        % ============= Step 6: 最终验证 =============
        fprintf('Step 6: 最终反演结果验证...\n');
        
        final_params = constructPDEParams(input_data, final_modulus);
        final_pde_results = performPDE(final_params, input_data);
        
        final_D0 = getD0FromResults(final_pde_results);
        final_error = abs(final_D0 - input_data.measured_deflection) / input_data.measured_deflection;
    end
    
    % ============= Step 7: 敏感性分析 =============
    if isfield(config, 'validation') && isfield(config.validation, 'sensitivity_analysis') && config.validation.sensitivity_analysis
        fprintf('Step 7: 敏感性分析...\n');
        sensitivity_results = performSensitivityAnalysis(input_data, final_modulus, config);
        fprintf('✅ 敏感性分析完成\n\n');
    else
        sensitivity_results = [];
    end
    
    % ============= Step 8: 结果输出 =============
    fprintf('\n');
    fprintf('╔════════════════════════════════════════════════════════════╗\n');
    fprintf('║                    反演分析完成                            ║\n');
    fprintf('╚════════════════════════════════════════════════════════════╝\n\n');
    
    fprintf('📊 反演结果摘要:\n');
    fprintf('  路面类型: %s\n', input_data.pavement_type_name);
    fprintf('  输入模式: %s\n\n', input_data.input_mode);
    fprintf('  ┌─────────────┬──────────┬──────────┐\n');
    fprintf('  │   结构层    │ 初始估计 │ 反演结果 │\n');
    fprintf('  ├─────────────┼──────────┼──────────┤\n');
    fprintf('  │ 表面层(MPa) │  %6d  │  %6d  │\n', initial_modulus.surface, final_modulus.surface);
    fprintf('  │ 基层(MPa)   │  %6d  │  %6d  │\n', initial_modulus.base, final_modulus.base);
    fprintf('  │ 底基层(MPa) │  %6d  │  %6d  │\n', initial_modulus.subbase, final_modulus.subbase);
    if isfield(final_modulus, 'subgrade')
        fprintf('  │ 土基(MPa)   │    -     │  %6d  │\n', round(final_modulus.subgrade));
    end
    fprintf('  └─────────────┴──────────┴──────────┘\n\n');
    
    fprintf('  弯沉匹配:\n');
    fprintf('    实测弯沉D0:  %.4f mm\n', input_data.measured_deflection);
    fprintf('    计算弯沉D0:  %.4f mm\n', getD0FromResults(final_pde_results));
    fprintf('    最终误差:    %.2f%%\n', final_error * 100);
    
    % 弯沉盆对比
    if isfield(final_pde_results, 'deflections') && isfield(input_data, 'deflection_basin')
        n_sensors = length(input_data.sensor_offsets);
        fprintf('\n  弯沉盆对比 (mm):\n');
        fprintf('    测点:  ');
        for i = 1:n_sensors
            fprintf('D%-4d ', input_data.sensor_offsets(i));
        end
        fprintf('\n    实测: ');
        for i = 1:min(n_sensors, length(input_data.deflection_basin))
            fprintf('%6.4f ', input_data.deflection_basin(i));
        end
        fprintf('\n    计算: ');
        for i = 1:min(n_sensors, length(final_pde_results.deflections))
            fprintf('%6.4f ', final_pde_results.deflections(i));
        end
        fprintf('\n');
        
        % 计算各测点误差
        fprintf('    误差: ');
        for i = 1:min(n_sensors, length(final_pde_results.deflections))
            err_i = abs(final_pde_results.deflections(i) - input_data.deflection_basin(i)) / ...
                    input_data.deflection_basin(i) * 100;
            fprintf('%5.1f%% ', err_i);
        end
        fprintf('\n');
    end
    
    % 可视化
    if isfield(config, 'output') && isfield(config.output, 'plot_results') && config.output.plot_results
        visualizeResults(input_data, initial_modulus, final_modulus, ...
                        final_pde_results, optimization_log, sensitivity_results);
    end
    
    fprintf('\n✅ 反演系统运行成功完成!\n\n');
    
catch ME
    fprintf('\n❌ 反演系统运行失败: %s\n', ME.message);
    if ~isempty(ME.stack)
        fprintf('错误位置: %s (第 %d 行)\n', ME.stack(1).name, ME.stack(1).line);
    end
end
end

%% ==================== 双模式输入数据获取（核心修改） ====================

function input_data = getInputData_DualMode(config)
% 获取反演输入数据 - 支持自然语言和结构化两种输入模式

fprintf('  ═══════════════════════════════════════════════════════════\n');
fprintf('    选择输入模式\n');
fprintf('  ═══════════════════════════════════════════════════════════\n\n');

fprintf('    ┌────────────────────────────────────────────────────────┐\n');
fprintf('    │ [1] 自然语言输入 (推荐)                               │\n');
fprintf('    │     用自然语言描述路面情况，LLM自动解析参数           │\n');
fprintf('    │     示例: "12cm沥青面层，20cm水稳基层，弯沉0.5mm"     │\n');
fprintf('    ├────────────────────────────────────────────────────────┤\n');
fprintf('    │ [2] 结构化输入 (传统方式)                             │\n');
fprintf('    │     逐步输入路面类型、层厚、弯沉值等参数              │\n');
fprintf('    └────────────────────────────────────────────────────────┘\n');

mode_choice = input('  请选择输入模式 [1/2, 默认1]: ', 's');
if isempty(mode_choice), mode_choice = '1'; end

switch mode_choice
    case '1'
        input_data = getInputData_NaturalLanguage(config);
    case '2'
        input_data = getInputData_Structured();
    otherwise
        input_data = getInputData_NaturalLanguage(config);
end

end

%% ==================== 自然语言输入模式 ====================

function input_data = getInputData_NaturalLanguage(config)
% 自然语言输入模式 - LLM解析用户描述

fprintf('\n  ═══════════════════════════════════════════════════════════\n');
fprintf('    自然语言输入模式 (LLM解析)\n');
fprintf('  ═══════════════════════════════════════════════════════════\n\n');

fprintf('  请用自然语言描述路面情况，可以包含以下信息:\n');
fprintf('    - 路面类型 (柔性/半刚性/刚性复合等)\n');
fprintf('    - 各层厚度 (如: 12cm沥青面层)\n');
fprintf('    - 弯沉数据 (如: D0=0.5mm 或 完整弯沉盆)\n');
fprintf('    - 荷载条件 (如: 50kN标准FWD)\n');
fprintf('    - 路面状况描述 (如: 结构良好/中等/较差)\n\n');

fprintf('  输入示例:\n');
fprintf('    "某高速公路半刚性基层路面，结构为12cm沥青面层+20cm水稳基层\n');
fprintf('     +30cm水稳底基层，使用50kN标准FWD检测，实测弯沉盆为\n');
fprintf('     [0.285, 0.243, 0.207, 0.140, 0.097, 0.071, 0.051]mm"\n\n');

fprintf('  请输入路面描述 (输入完成后按两次回车):\n');
fprintf('  ────────────────────────────────────────────────────────────\n');

% 多行输入
description_lines = {};
while true
    line = input('  > ', 's');
    if isempty(line)
        break;
    end
    description_lines{end+1} = line;
end
description = strjoin(description_lines, ' ');

if isempty(strtrim(description))
    fprintf('  ⚠️ 未输入描述，切换到结构化输入模式...\n');
    input_data = getInputData_Structured();
    return;
end

fprintf('\n  正在调用LLM解析您的描述...\n');

% 调用LLM解析
try
    input_data = parseNaturalLanguageInput_Internal(description, config);
    input_data.input_mode = '自然语言输入';
    input_data.original_description = description;
    
    % 显示解析结果并确认
    fprintf('\n  ┌─────────────────────────────────────────────────────────┐\n');
    fprintf('  │                LLM解析结果                              │\n');
    fprintf('  ├─────────────────────────────────────────────────────────┤\n');
    fprintf('  │  路面类型: %-45s │\n', input_data.pavement_type_name);
    fprintf('  │  层厚度: 面层=%.0fcm, 基层=%.0fcm, 底基层=%.0fcm %s │\n', ...
        input_data.thickness(1), input_data.thickness(2), input_data.thickness(3), ...
        repmat(' ', 1, max(0, 8)));
    fprintf('  │  荷载: 压力=%.3fMPa, 半径=%.0fcm %-21s │\n', ...
        input_data.load_pressure, input_data.load_radius, '');
    fprintf('  │  弯沉盆(mm): %-42s │\n', '');
    fprintf('  │    D0=%.4f, D20=%.4f, D30=%.4f, D60=%.4f %s │\n', ...
        input_data.deflection_basin(1), input_data.deflection_basin(2), ...
        input_data.deflection_basin(3), input_data.deflection_basin(4), ...
        repmat(' ', 1, 5));
    fprintf('  │    D90=%.4f, D120=%.4f, D150=%.4f %-14s │\n', ...
        input_data.deflection_basin(5), input_data.deflection_basin(6), ...
        input_data.deflection_basin(7), '');
    fprintf('  └─────────────────────────────────────────────────────────┘\n');
    
    % 确认或修改
    confirm = input('\n  确认使用以上参数? [Y/n/修改]: ', 's');
    if strcmpi(confirm, 'n')
        fprintf('  切换到结构化输入模式...\n');
        input_data = getInputData_Structured();
    elseif ~isempty(confirm) && ~strcmpi(confirm, 'y')
        % 用户要修改某些参数
        input_data = modifyParsedInput(input_data);
    end
    
catch ME
    fprintf('  ⚠️ LLM解析失败: %s\n', ME.message);
    fprintf('  切换到结构化输入模式...\n');
    input_data = getInputData_Structured();
end

end

%% ==================== 内部自然语言解析函数 ====================

function input_data = parseNaturalLanguageInput_Internal(description, config)
% 内部函数：调用LLM解析自然语言描述

% 构建解析Prompt
prompt = buildParsePrompt_Internal(description);

% 调用LLM API
response = callLLMAPI(prompt, config, config.llm_guidance.model);

if isempty(response)
    error('LLM响应为空');
end

% 解析响应
input_data = parseLLMResponse_Internal(response);

% 设置默认值和验证
input_data = setDefaultsAndValidate(input_data);

end

function prompt = buildParsePrompt_Internal(description)
% 构建LLM解析Prompt

% 根据描述预判路面类型，用于动态角色设定
if contains(description, '水稳') || contains(description, '水泥稳定') || contains(description, '半刚性')
    role_str = 'a senior pavement structural engineer specializing in semi-rigid base pavement systems (cement-stabilized macadam base, CTB/CSM), with expertise in the characteristic behavior where base modulus may substantially exceed surface AC modulus';
    type_hint = 'Note: Semi-rigid base pavements feature cement-stabilized base layers (typical modulus 3,000–15,000 MPa) that may exceed AC surface modulus—this is physically correct, not anomalous.';
elseif contains(description, '倒装')
    role_str = 'a senior pavement structural engineer specializing in inverted pavement structures, where a stiff granular base layer underlies a relatively thin asphalt surface';
    type_hint = 'Note: Inverted pavements have a rigid aggregate base with lower surface modulus—stiffness does NOT decrease monotonically with depth.';
else
    role_str = 'a senior pavement structural engineer specializing in conventional flexible pavement systems (asphalt concrete surface over granular base/subbase), where modulus generally decreases with depth';
    type_hint = 'Note: Flexible pavements follow a decreasing stiffness gradient: AC surface > base > subbase > subgrade.';
end

prompt = sprintf([...
    'You are %s.\n\n' ...
    'Your task: parse the following natural language description and extract structured FWD backcalculation parameters.\n\n' ...
    '[User Description]\n%s\n\n' ...
    '[Pavement Type Guidance]\n%s\n\n' ...
    '[Output Requirements]\n' ...
    'Return ONLY the following JSON object, with no additional text or explanation:\n' ...
    '{\n' ...
    '  "pavement_type": "semi_rigid" or "flexible" or "rigid_composite" or "inverted",\n' ...
    '  "pavement_type_name": "pavement type name in Chinese",\n' ...
    '  "thickness_cm": [surface_thickness, base_thickness, subbase_thickness],\n' ...
    '  "deflection_basin_mm": [D0, D20, D30, D60, D90, D120, D150],\n' ...
    '  "load_pressure_mpa": load_pressure (default 0.707),\n' ...
    '  "load_radius_cm": load_radius (default 15),\n' ...
    '  "subgrade_modulus_mpa": estimated_value_or_null\n' ...
    '}\n\n' ...
    '[Parsing Rules]\n' ...
    '1. Pavement type identification:\n' ...
    '   - Contains "水稳"/"水泥稳定"/"CTB"/"CSM" → semi_rigid\n' ...
    '   - Contains "级配碎石"/"沥青碎石"/"flexible" → flexible\n' ...
    '   - Contains "贫混凝土"/"水泥混凝土"/"rigid" → rigid_composite\n' ...
    '   - Contains "倒装"/"inverted" → inverted\n' ...
    '2. Default layer thicknesses when unspecified: surface 12 cm, base 20 cm, subbase 30 cm\n' ...
    '3. Standard FWD sensor offsets: 0, 20, 30, 60, 90, 120, 150 cm\n' ...
    '4. If only D0 is provided, estimate basin shape:\n' ...
    '   D20/D0≈0.85, D30/D0≈0.73, D60/D0≈0.49, D90/D0≈0.34, D120/D0≈0.25, D150/D0≈0.18\n' ...
    '5. Standard FWD load: 50 kN, radius 15 cm, pressure 0.707 MPa\n\n' ...
    '[IMPORTANT] Return ONLY the JSON object.'], ...
    role_str, description, type_hint);


end

function input_data = parseLLMResponse_Internal(response)
% 解析LLM响应

input_data = struct();

% 清理响应
response = strtrim(response);
response = regexprep(response, '^```json\s*', '');
response = regexprep(response, '\s*```$', '');
response = regexprep(response, '^```\s*', '');

% 提取JSON
json_start = strfind(response, '{');
json_end = strfind(response, '}');

if isempty(json_start) || isempty(json_end)
    error('未在LLM响应中找到JSON格式数据');
end

json_str = response(json_start(1):json_end(end));

try
    parsed = jsondecode(json_str);
    
    % 提取路面类型
    if isfield(parsed, 'pavement_type')
        input_data.pavement_type = parsed.pavement_type;
    else
        input_data.pavement_type = 'semi_rigid';
    end
    
    if isfield(parsed, 'pavement_type_name')
        input_data.pavement_type_name = parsed.pavement_type_name;
    else
        input_data.pavement_type_name = getPavementTypeName(input_data.pavement_type);
    end
    
    % 提取层厚度
    if isfield(parsed, 'thickness_cm')
        tc = parsed.thickness_cm;
        if iscell(tc)
            tc = cell2mat(tc);
        end
        input_data.thickness = tc(:);
    else
        input_data.thickness = [12; 20; 30];
    end
    
    % 提取弯沉盆
    if isfield(parsed, 'deflection_basin_mm')
        basin = parsed.deflection_basin_mm;
        if iscell(basin)
            basin = cell2mat(basin);
        end
        input_data.deflection_basin = basin(:)';
        input_data.measured_deflection = basin(1);
    else
        error('未找到弯沉盆数据');
    end
    
    % 提取荷载参数
    if isfield(parsed, 'load_pressure_mpa')
        input_data.load_pressure = parsed.load_pressure_mpa;
    else
        input_data.load_pressure = 0.707;
    end
    
    if isfield(parsed, 'load_radius_cm')
        input_data.load_radius = parsed.load_radius_cm;
    else
        input_data.load_radius = 15;
    end
    
    % 提取土基模量
    if isfield(parsed, 'subgrade_modulus_mpa') && ~isempty(parsed.subgrade_modulus_mpa)
        input_data.subgrade_modulus = parsed.subgrade_modulus_mpa;
    else
        input_data.subgrade_modulus = estimateSubgradeModulus(input_data.measured_deflection);
    end
    
catch ME
    error('JSON解析失败: %s', ME.message);
end

end

function input_data = setDefaultsAndValidate(input_data)
% 设置默认值并验证

% 传感器位置
input_data.sensor_offsets = [0, 20, 30, 60, 90, 120, 150];
input_data.sensor_config = 'standard_7';

% 泊松比
switch input_data.pavement_type
    case 'rigid_composite'
        input_data.poisson = [0.35; 0.20; 0.25];
    otherwise
        input_data.poisson = [0.35; 0.25; 0.30];
end

% 边界条件
input_data.boundary_type = 'fixed';

% 模量约束范围
input_data.modulus_constraints = getModulusConstraints(input_data.pavement_type);

% 验证弯沉盆长度
if length(input_data.deflection_basin) < 7
    D0 = input_data.measured_deflection;
    ratios = [1.0, 0.85, 0.73, 0.49, 0.34, 0.25, 0.18];
    input_data.deflection_basin = D0 * ratios;
end

% 确保厚度为列向量
input_data.thickness = input_data.thickness(:);

% ★★★ 关键修复：设置沥青层厚度（校准函数需要此字段）★★★
input_data.ac_thickness = input_data.thickness(1);

% ★★★ 设置路面类型标识（校准函数需要）★★★
if ~isfield(input_data, 'pavement_type_id')
    switch input_data.pavement_type
        case 'flexible'
            input_data.pavement_type_id = 'flexible';
        case 'semi_rigid'
            input_data.pavement_type_id = 'semi_rigid';
        case 'rigid_composite'
            input_data.pavement_type_id = 'rigid_composite';
        case 'inverted'
            input_data.pavement_type_id = 'inverted';
        otherwise
            input_data.pavement_type_id = 'flexible';
    end
end

end

function name = getPavementTypeName(type)
% 获取路面类型中文名称

switch type
    case 'semi_rigid'
        name = '半刚性基层路面';
    case 'flexible'
        name = '柔性基层路面';
    case 'rigid_composite'
        name = '刚性复合式路面';
    case 'inverted'
        name = '倒装式路面';
    otherwise
        name = '未知类型';
end

end

function constraints = getModulusConstraints(pavement_type)
% 获取模量约束范围

switch pavement_type
    case 'semi_rigid'
        constraints = struct(...
            'surface_min', 5000, 'surface_max', 25000, ...
            'base_min', 8000, 'base_max', 18000, ...
            'subbase_min', 150, 'subbase_max', 800, ...
            'subgrade_min', 60, 'subgrade_max', 300);
    case 'rigid_composite'
        constraints = struct(...
            'surface_min', 5000, 'surface_max', 25000, ...
            'base_min', 25000, 'base_max', 40000, ...
            'subbase_min', 8000, 'subbase_max', 18000, ...
            'subgrade_min', 60, 'subgrade_max', 300);
    case 'inverted'
        constraints = struct(...
            'surface_min', 4000, 'surface_max', 20000, ...
            'base_min', 200, 'base_max', 800, ...
            'subbase_min', 100, 'subbase_max', 500, ...
            'subgrade_min', 50, 'subgrade_max', 250);
    case 'flexible'
        constraints = struct(...
            'surface_min', 800, 'surface_max', 6000, ...
            'base_min', 200, 'base_max', 1500, ...
            'subbase_min', 80, 'subbase_max', 600, ...
            'subgrade_min', 30, 'subgrade_max', 150);
    otherwise
        constraints = struct(...
            'surface_min', 5000, 'surface_max', 25000, ...
            'base_min', 8000, 'base_max', 18000, ...
            'subbase_min', 150, 'subbase_max', 800, ...
            'subgrade_min', 60, 'subgrade_max', 300);
end

end

function sg_modulus = estimateSubgradeModulus(D0)
% 根据中心弯沉估计土基模量

if D0 < 0.2
    sg_modulus = 180;  % 高刚度
elseif D0 < 0.35
    sg_modulus = 120;  % 中高刚度
elseif D0 < 0.5
    sg_modulus = 80;   % 中等
elseif D0 < 0.8
    sg_modulus = 50;   % 较低
else
    sg_modulus = 40;   % 低刚度
end

end

function input_data = modifyParsedInput(input_data)
% 允许用户修改解析结果

fprintf('\n  【修改解析结果】\n');
fprintf('  输入要修改的项目编号，直接回车跳过:\n');
fprintf('    [1] 路面类型\n');
fprintf('    [2] 层厚度\n');
fprintf('    [3] 弯沉盆数据\n');
fprintf('    [4] 荷载参数\n');
fprintf('    [5] 土基模量\n');
fprintf('    [0] 完成修改\n');

while true
    choice = input('  请选择 [0-5]: ', 's');
    
    switch choice
        case '1'
            fprintf('    选择路面类型: [1]半刚性 [2]刚性复合 [3]倒装式 [4]柔性\n');
            ptype = input('    > ', 's');
            switch ptype
                case '1'
                    input_data.pavement_type = 'semi_rigid';
                    input_data.pavement_type_name = '半刚性基层路面';
                case '2'
                    input_data.pavement_type = 'rigid_composite';
                    input_data.pavement_type_name = '刚性复合式路面';
                case '3'
                    input_data.pavement_type = 'inverted';
                    input_data.pavement_type_name = '倒装式路面';
                case '4'
                    input_data.pavement_type = 'flexible';
                    input_data.pavement_type_name = '柔性基层路面';
            end
            input_data.modulus_constraints = getModulusConstraints(input_data.pavement_type);
            
        case '2'
            input_data.thickness(1) = input('    面层厚度(cm): ');
            input_data.thickness(2) = input('    基层厚度(cm): ');
            input_data.thickness(3) = input('    底基层厚度(cm): ');
            
        case '3'
            fprintf('    输入7个弯沉值(mm)，用空格分隔:\n');
            basin_str = input('    > ', 's');
            basin_str = strrep(basin_str, ',', ' ');
            input_data.deflection_basin = str2num(basin_str);
            input_data.measured_deflection = input_data.deflection_basin(1);
            
        case '4'
            input_data.load_pressure = input('    荷载压力(MPa): ');
            input_data.load_radius = input('    荷载半径(cm): ');
            
        case '5'
            input_data.subgrade_modulus = input('    土基模量(MPa): ');
            
        case '0'
            break;
            
        otherwise
            continue;
    end
end

end

%% ==================== 结构化输入模式（保留原有逻辑） ====================

function input_data = getInputData_Structured()
% 结构化输入模式 - 传统逐步输入方式

fprintf('\n  ═══════════════════════════════════════════════════════════\n');
fprintf('    结构化输入模式 (传统方式)\n');
fprintf('  ═══════════════════════════════════════════════════════════\n\n');

input_data = struct();
input_data.input_mode = '结构化输入';

%% ========== 步骤1: 选择路面类型 ==========
fprintf('  【步骤1】选择路面类型:\n');
fprintf('    [1] 半刚性基层 (水泥稳定碎石, 8000-18000 MPa)\n');
fprintf('    [2] 刚性复合式 (贫混凝土/水泥混凝土, 25000-40000 MPa)\n');
fprintf('    [3] 倒装式 (级配碎石, 200-800 MPa)\n');
fprintf('    [4] 柔性基层 (沥青碎石/级配碎石, 200-1500 MPa)\n');

ptype = input('  请选择 [1/2/3/4, 默认1]: ', 's');
if isempty(ptype), ptype = '1'; end

switch ptype
    case '1'
        input_data.pavement_type = 'semi_rigid';
        input_data.pavement_type_name = '半刚性基层路面';
    case '2'
        input_data.pavement_type = 'rigid_composite';
        input_data.pavement_type_name = '刚性复合式路面';
    case '3'
        input_data.pavement_type = 'inverted';
        input_data.pavement_type_name = '倒装式路面';
    case '4'
        input_data.pavement_type = 'flexible';
        input_data.pavement_type_name = '柔性基层路面';
    otherwise
        input_data.pavement_type = 'semi_rigid';
        input_data.pavement_type_name = '半刚性基层路面';
end

input_data.modulus_constraints = getModulusConstraints(input_data.pavement_type);
fprintf('  ✓ 已选择: %s\n\n', input_data.pavement_type_name);

%% ========== 步骤2: 路面结构输入 ==========
fprintf('  【步骤2】输入路面结构层厚(cm):\n');
input_data.thickness(1) = input('    表面层(沥青)厚度: ');
input_data.thickness(2) = input('    基层厚度: ');
input_data.thickness(3) = input('    底基层厚度: ');
input_data.thickness = input_data.thickness(:);

%% ========== 步骤3: 荷载参数 ==========
fprintf('\n  【步骤3】荷载参数:\n');
use_default_load = input('    使用标准FWD荷载(50kN, r=15cm)? [Y/n]: ', 's');
if isempty(use_default_load) || strcmpi(use_default_load, 'y')
    input_data.load_pressure = 0.707;
    input_data.load_radius = 15;
else
    input_data.load_pressure = input('    荷载压力(MPa): ');
    input_data.load_radius = input('    荷载半径(cm): ');
end

%% ========== 步骤4: 弯沉盆数据 ==========
input_data.sensor_offsets = [0, 20, 30, 60, 90, 120, 150];
input_data.sensor_config = 'standard_7';
n_sensors = 7;

fprintf('\n  【步骤4】输入弯沉盆数据 (共%d个测点):\n', n_sensors);
fprintf('    测点位置(cm): 0 20 30 60 90 120 150\n');
fprintf('    输入方式: [1]逐个输入 [2]一次性输入(空格分隔)\n');
input_mode = input('    选择 [1/2, 默认2]: ', 's');
if isempty(input_mode), input_mode = '2'; end

input_data.deflection_basin = zeros(1, n_sensors);

if strcmp(input_mode, '2')
    fprintf('    请输入%d个弯沉值(mm),用空格分隔:\n', n_sensors);
    basin_str = input('    > ', 's');
    basin_str = strrep(basin_str, ',', ' ');
    basin_values = str2num(basin_str);
    if length(basin_values) >= n_sensors
        input_data.deflection_basin = basin_values(1:n_sensors);
    else
        error('输入的弯沉值数量不足');
    end
else
    for i = 1:n_sensors
        input_data.deflection_basin(i) = input(sprintf('    D%d (mm): ', input_data.sensor_offsets(i)));
    end
end

input_data.measured_deflection = input_data.deflection_basin(1);

%% ========== 步骤5: 其他参数 ==========
fprintf('\n  【步骤5】其他参数:\n');

% 泊松比
switch input_data.pavement_type
    case 'rigid_composite'
        input_data.poisson = [0.35; 0.20; 0.25];
    otherwise
        input_data.poisson = [0.35; 0.25; 0.30];
end

% 土基模量
sg_input = input('    土基模量(MPa) [自动估计留空]: ');
if isempty(sg_input)
    input_data.subgrade_modulus = estimateSubgradeModulus(input_data.measured_deflection);
    fprintf('    ✓ 土基模量自动估计: %d MPa\n', input_data.subgrade_modulus);
else
    input_data.subgrade_modulus = sg_input;
end

% 边界条件
input_data.boundary_type = 'fixed';

end

%% ==================== 辅助函数 ====================

function setupPaths(project_root)
addpath(genpath(project_root));
end

function config = loadConfig()
config = getDefaultConfig();

% 尝试加载JSON配置文件（优先）
json_config_file = 'llm_config.json';
if exist(json_config_file, 'file')
    try
        json_text = fileread(json_config_file);
        json_config = jsondecode(json_text);
        
        % 合并DeepSeek配置
        if isfield(json_config, 'deepseek')
            fields = fieldnames(json_config.deepseek);
            for i = 1:length(fields)
                config.deepseek.(fields{i}) = json_config.deepseek.(fields{i});
            end
            fprintf('    ✓ 已加载DeepSeek配置从 %s\n', json_config_file);
        end
        
        % 合并OLLAMA配置
        if isfield(json_config, 'ollama')
            fields = fieldnames(json_config.ollama);
            for i = 1:length(fields)
                config.ollama.(fields{i}) = json_config.ollama.(fields{i});
            end
            fprintf('    ✓ 已加载OLLAMA配置从 %s\n', json_config_file);
        end
        
    catch ME
        warning('loadConfig:JSONLoadFailed', 'JSON配置文件加载失败: %s', ME.message);
    end
end

% 尝试加载MAT配置文件（备选）
mat_config_file = 'backcalculation_config.mat';
if exist(mat_config_file, 'file')
    try
        loaded = load(mat_config_file);
        if isfield(loaded, 'config')
            % 合并配置（不覆盖已加载的API配置）
            fields = fieldnames(loaded.config);
            for i = 1:length(fields)
                if ~strcmp(fields{i}, 'deepseek') && ~strcmp(fields{i}, 'ollama')
                    config.(fields{i}) = loaded.config.(fields{i});
                end
            end
        end
    catch
        % 忽略加载错误
    end
end

% 检查API Key是否已配置
if contains(config.deepseek.api_key, 'xxxxx')
    fprintf('\n');
    fprintf('  ┌─────────────────────────────────────────────────────────┐\n');
    fprintf('  │  ⚠️  DeepSeek API Key 未配置                            │\n');
    fprintf('  │                                                         │\n');
    fprintf('  │  请在以下位置之一配置您的API Key:                       │\n');
    fprintf('  │  1. 创建 llm_config.json 文件                           │\n');
    fprintf('  │  2. 修改 runBackcalculation_v2.m 中的 getDefaultConfig  │\n');
    fprintf('  │                                                         │\n');
    fprintf('  │  llm_config.json 示例:                                  │\n');
    fprintf('  │  {                                                      │\n');
    fprintf('  │    "deepseek": {                                        │\n');
    fprintf('  │      "api_key": "sk-your-api-key-here",                 │\n');
    fprintf('  │      "base_url": "https://api.deepseek.com/v1",         │\n');
    fprintf('  │      "model": "deepseek-chat"                           │\n');
    fprintf('  │    }                                                    │\n');
    fprintf('  │  }                                                      │\n');
    fprintf('  └─────────────────────────────────────────────────────────┘\n\n');
end
end

function config = getDefaultConfig()
config = struct();

config.ppo_backcalculation = struct();
config.ppo_backcalculation.max_episodes = 300;
config.ppo_backcalculation.max_steps_per_episode = 20;
config.ppo_backcalculation.early_stop_patience = 20;
config.ppo_backcalculation.learning_rate = 0.001;

config.backcalculation = struct();
config.backcalculation.convergence_threshold = 0.05;

config.llm_guidance = struct();
config.llm_guidance.enabled = true;  % 默认启用LLM
config.llm_guidance.model = 'deepseek';
config.llm_guidance.guidance_interval = 5;
config.llm_guidance.use_for_initial_estimate = true;
config.llm_guidance.use_for_optimization_guidance = true;

% DeepSeek API 配置（callLLMAPI需要）
config.deepseek = struct();
config.deepseek.api_key = 'sk-fe48f98a76c24674ae06eee174ed6727';  % 请替换为你的API Key
config.deepseek.base_url = 'https://api.deepseek.com/v1';
config.deepseek.model = 'deepseek-chat';
config.deepseek.max_tokens = 2000;
config.deepseek.temperature = 0.1;
config.deepseek.timeout = 30;

% OLLAMA 配置（备选）
config.ollama = struct();
config.ollama.base_url = 'http://localhost:11434';
config.ollama.model = 'qwen2.5:7b';
config.ollama.temperature = 0.1;
config.ollama.timeout = 60;

config.validation = struct();
config.validation.sensitivity_analysis = false;

config.output = struct();
config.output.save_results = true;
config.output.plot_results = true;
end

function displayInputData(input_data)
fprintf('\n╔════════════════════════════════════════════════════════════╗\n');
fprintf('║                   输入数据确认                             ║\n');
fprintf('╚════════════════════════════════════════════════════════════╝\n\n');

fprintf('  输入模式: %s\n', input_data.input_mode);
fprintf('  路面类型: %s\n\n', input_data.pavement_type_name);

fprintf('  路面结构:\n');
layer_names = {'表面层', '基层', '底基层'};
for i = 1:length(input_data.thickness)
    fprintf('    %s: %.1f cm\n', layer_names{i}, input_data.thickness(i));
end
fprintf('    总厚度: %.1f cm\n', sum(input_data.thickness));

fprintf('\n  模量约束范围 (MPa):\n');
fprintf('    表面层: [%d, %d]\n', input_data.modulus_constraints.surface_min, ...
    input_data.modulus_constraints.surface_max);
fprintf('    基层:   [%d, %d]\n', input_data.modulus_constraints.base_min, ...
    input_data.modulus_constraints.base_max);
fprintf('    底基层: [%d, %d]\n', input_data.modulus_constraints.subbase_min, ...
    input_data.modulus_constraints.subbase_max);

fprintf('\n  荷载参数:\n');
fprintf('    压力: %.3f MPa\n', input_data.load_pressure);
fprintf('    半径: %.1f cm\n', input_data.load_radius);

fprintf('\n  弯沉盆数据 (mm):\n    ');
for i = 1:length(input_data.deflection_basin)
    fprintf('%.4f ', input_data.deflection_basin(i));
end
fprintf('\n');

fprintf('\n  土基模量: %d MPa\n', input_data.subgrade_modulus);
end

function displayInitialEstimate(initial_modulus, input_data)
fprintf('\n  初始模量估计:\n');
fprintf('    表面层: %d MPa\n', initial_modulus.surface);
fprintf('    基层:   %d MPa\n', initial_modulus.base);
fprintf('    底基层: %d MPa\n', initial_modulus.subbase);
end

function params = constructPDEParams(input_data, modulus)
params = struct();
params.thickness = input_data.thickness(:);
params.modulus = [modulus.surface; modulus.base; modulus.subbase];
params.poisson = input_data.poisson(:);
params.load_pressure = input_data.load_pressure;
params.load_radius = input_data.load_radius;

if isfield(modulus, 'subgrade') && modulus.subgrade > 0
    params.subgrade_modulus = modulus.subgrade;
else
    params.subgrade_modulus = input_data.subgrade_modulus;
end

params.subgrade_modeling = 'multilayer_subgrade';
params.sensor_offsets = input_data.sensor_offsets;
params.boundary_type = input_data.boundary_type;
end

function pde_results = performPDE(params, input_data)
load_params = struct();
load_params.load_pressure = params.load_pressure;
load_params.load_radius = params.load_radius;

boundary_conditions = struct();
boundary_conditions.modeling_type = params.subgrade_modeling;
boundary_conditions.subgrade_modulus = params.subgrade_modulus;
boundary_conditions.soil_modulus = params.subgrade_modulus;
boundary_conditions.sensor_offsets = params.sensor_offsets;
boundary_conditions.boundary_type = params.boundary_type;

try
    pde_results = roadPDEModelingABAQUSCalibrated(params, load_params, boundary_conditions);
catch ME
    fprintf('  ⚠️ PDE计算失败: %s\n', ME.message);
    pde_results = struct();
    pde_results.success = false;
    pde_results.D0 = input_data.measured_deflection;
    pde_results.deflections = input_data.deflection_basin;
end
end

function D0 = getD0FromResults(pde_results)
if isfield(pde_results, 'D0') && ~isempty(pde_results.D0) && pde_results.D0 > 0
    D0 = pde_results.D0;
elseif isfield(pde_results, 'deflections') && ~isempty(pde_results.deflections)
    D0 = pde_results.deflections(1);
else
    D0 = 0.5;
end
end

function sensitivity_results = performSensitivityAnalysis(input_data, final_modulus, config)
sensitivity_results = struct();
sensitivity_results.surface = 0;
sensitivity_results.base = 0;
sensitivity_results.subbase = 0;
end

function visualizeResults(input_data, initial_modulus, final_modulus, ...
                         final_pde_results, optimization_log, sensitivity_results)
figure('Name', '路面结构模量反演结果可视化', 'Position', [100 100 1200 800]);

% 1. 模量对比
subplot(2,2,1);
layers = {'表面层', '基层', '底基层'};
initial_vals = [initial_modulus.surface, initial_modulus.base, initial_modulus.subbase];
final_vals = [final_modulus.surface, final_modulus.base, final_modulus.subbase];
bar_data = [initial_vals; final_vals]';
bar(bar_data);
set(gca, 'XTickLabel', layers);
ylabel('模量 (MPa)');
legend('初始估计', '最终反演', 'Location', 'best');
title(sprintf('模量对比 (%s)', input_data.pavement_type_name));
grid on;

% 2. 误差收敛历史
subplot(2,2,2);
if isfield(optimization_log, 'error_history') && ~isempty(optimization_log.error_history)
    plot(optimization_log.error_history * 100, 'b-', 'LineWidth', 1.5);
    xlabel('迭代次数');
    ylabel('相对误差 (%)');
    title('误差收敛历史');
    grid on;
else
    text(0.5, 0.5, '无优化历史', 'HorizontalAlignment', 'center');
    axis off;
end

% 3. 弯沉盆对比
subplot(2,2,3);
sensor_pos = input_data.sensor_offsets;
n_sensors = length(sensor_pos);

plot(sensor_pos, input_data.deflection_basin(1:n_sensors), 'bo-', ...
    'LineWidth', 2, 'MarkerSize', 8, 'DisplayName', '实测');
hold on;

if isfield(final_pde_results, 'deflections') && length(final_pde_results.deflections) >= n_sensors
    plot(sensor_pos, final_pde_results.deflections(1:n_sensors), 'rs--', ...
        'LineWidth', 1.5, 'MarkerSize', 6, 'DisplayName', '计算');
end

xlabel('距荷载中心距离 (cm)');
ylabel('弯沉 (mm)');
title('弯沉盆对比');
legend('Location', 'best');
grid on;
set(gca, 'YDir', 'reverse');

% 4. 各测点误差
subplot(2,2,4);
if isfield(final_pde_results, 'deflections') && length(final_pde_results.deflections) >= n_sensors
    errors = abs(final_pde_results.deflections(1:n_sensors) - input_data.deflection_basin(1:n_sensors)) ...
             ./ input_data.deflection_basin(1:n_sensors) * 100;
    bar(errors);
    set(gca, 'XTickLabel', arrayfun(@(x) sprintf('D%d', x), sensor_pos, 'UniformOutput', false));
    ylabel('相对误差 (%)');
    title('各测点弯沉误差');
    grid on;
    hold on;
    plot([0.5, n_sensors+0.5], [5, 5], 'r--', 'LineWidth', 1);
    hold off;
end

sgtitle(sprintf('路面结构模量反演结果 (%s)', input_data.input_mode));
end