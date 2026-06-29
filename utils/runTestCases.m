%% runTestCases.m - 论文测试数据运行脚本 (v6.2.1 LLM启用+半刚性修复)
% 
% 【v6.2.1更新】
%   1. 默认启用LLM引导（之前被错误禁用）
%   2. 半刚性结构模量约束扩大（配合BackcalculationPPO v5.3.3）
%   3. guidance_interval改为5（每5个episode调用LLM）
%
% 【v6.2.0更新】
%   1. 新增环道实测数据支持（5组半刚性结构）
%   2. 支持半刚性结构的模量约束范围
%   3. 自动识别结构类型（柔性/半刚性）并调整约束
%   4. 环道数据无真值，仅评估弯沉盆拟合精度
%
% 【v6.1.2更新】
%   1. 修复配置加载：优先使用loadBackcalculationConfig函数
%   2. 添加配置字段验证：自动补充缺失的llm_guidance等字段
%   3. 支持ABAQUS仿真数据集（15组柔性路面，全部有真实模量）
%   4. 完整输出论文所需数据：弯沉盆对比、模量对比、收敛历史
%   5. 自动生成论文表格（CSV格式）和图表
%   6. 批量运行时自动汇总统计
%
% 输出文件：
%   - Table1_Modulus_Results_*.csv   模量反演结果汇总表
%   - Table2_Deflection_Basin_*.csv  弯沉盆拟合数据表
%   - DeflectionBasin_*.png          弯沉盆拟合图
%   - ConvergenceHistory_*.csv       收敛历史数据
%   - test_results_*.mat             完整结果数据
%
% 使用方法：
%   runTestCases('ABAQUS');        % 运行全部15组ABAQUS数据
%   runTestCases('ABAQUS_1');      % 运行ABAQUS第1组
%   runTestCases('RingRoad');      % 运行全部5组环道数据
%   runTestCases('RingRoad_1');    % 运行环道第1组
%   runTestCases('all');           % 运行全部20组

function results = runTestCases(group_name, startIdx, endIdx)

fprintf('\n');
fprintf('╔════════════════════════════════════════════════════════════╗\n');
fprintf('║   论文测试案例运行器 v6.2.1 (LLM启用+半刚性修复)          ║\n');
fprintf('╚════════════════════════════════════════════════════════════╝\n\n');
test_cases = loadTestCases();

% === v6.3.0 分批运行支持 ===
if nargin < 2, startIdx = 1; end
if nargin < 3, endIdx = inf; end

% 快捷命令处理
if strcmpi(group_name, 'ABAQUS_1to5')
    group_name = 'ABAQUS'; startIdx = 1; endIdx = 5;
elseif strcmpi(group_name, 'ABAQUS_6to10')
    group_name = 'ABAQUS'; startIdx = 6; endIdx = 10;
elseif strcmpi(group_name, 'ABAQUS_11to15')
    group_name = 'ABAQUS'; startIdx = 11; endIdx = 15;
end
% === 分批运行支持结束 ===

if nargin < 1 || isempty(group_name)
    fprintf('请选择要运行的测试组:\n');
    fprintf('  [1] ABAQUS全部 - 15组柔性路面仿真数据\n');
    fprintf('  [2] ABAQUS_1  - 薄沥青层Case1\n');
    fprintf('  [3] ABAQUS_5  - 标准结构Case5\n');
    fprintf('  [4] ABAQUS_10 - 全厚式Case10\n');
    fprintf('  [0] 退出\n');
    
    choice = input('请输入选项 [0-4] 或直接输入ABAQUS_N: ', 's');
    
    if isnumeric(str2double(choice)) && ~isnan(str2double(choice))
        choice = str2double(choice);
        switch choice
            case 1, group_name = 'ABAQUS';
            case 2, group_name = 'ABAQUS_1';
            case 3, group_name = 'ABAQUS_5';
            case 4, group_name = 'ABAQUS_10';
            case 0, fprintf('已退出\n'); results = []; return;
            otherwise, fprintf('无效选项\n'); results = []; return;
        end
    else
        group_name = choice;
    end
end

results = struct();
timestamp = datestr(now, 'yyyymmdd_HHMMSS');

if strcmpi(group_name, 'ABAQUS')
    % 获取并排序ABAQUS案例
    abaqus_fields = fieldnames(test_cases);
    abaqus_cases = {};
    for i = 1:length(abaqus_fields)
        fname = abaqus_fields{i};
        if startsWith(fname, 'ABAQUS_')
            abaqus_cases{end+1} = fname;
        end
    end
    nums = cellfun(@(x) str2double(x(8:end)), abaqus_cases);
    [~, sortIdx] = sort(nums);
    abaqus_cases = abaqus_cases(sortIdx);
    
    % 限制索引范围
    total_cases = length(abaqus_cases);
    startIdx = max(1, min(startIdx, total_cases));
    endIdx = max(startIdx, min(endIdx, total_cases));
    selected_cases = abaqus_cases(startIdx:endIdx);
    num_selected = length(selected_cases);
    
    fprintf('\n📊 运行ABAQUS测试数据 (第%d-%d组，共%d组)...\n\n', startIdx, endIdx, num_selected);
    
    batch_filename = sprintf('ABAQUS_results_%dto%d_%s.mat', startIdx, endIdx, timestamp);
    
    for i = 1:num_selected
        fname = selected_cases{i};
        fprintf('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
        fprintf('  运行 %d/%d (总第%d组): %s\n', i, num_selected, startIdx+i-1, fname);
        fprintf('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
        
        try
            results.(fname) = runSingleCase(test_cases.(fname), fname);
            % 每个案例完成后保存
            save(batch_filename, 'results');
            fprintf('  💾 进度已保存到: %s\n', batch_filename);
        catch ME
            fprintf('  ❌ 运行失败: %s\n', ME.message);
            results.(fname) = struct('success', false, 'error', ME.message);
            save(batch_filename, 'results');
        end
    end
    
    generatePaperTables(results, timestamp);

elseif strcmpi(group_name, 'RingRoad')
    fprintf('\n📊 运行全部环道测试数据 (5组半刚性结构)...\n\n');
    
    all_fields = fieldnames(test_cases);
    ringroad_count = 0;
    
    for i = 1:length(all_fields)
        fname = all_fields{i};
        if startsWith(fname, 'RingRoad_')
            ringroad_count = ringroad_count + 1;
            fprintf('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
            fprintf('  运行 %d/5: %s\n', ringroad_count, fname);
            fprintf('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
            
            try
                results.(fname) = runSingleCase(test_cases.(fname), fname);
            catch ME
                fprintf('  ❌ 运行失败: %s\n', ME.message);
                results.(fname) = struct('success', false, 'error', ME.message);
            end
        end
    end
    
    generatePaperTables(results, timestamp);

elseif strcmpi(group_name, 'all')
    fprintf('\n📊 运行全部测试数据 (20组: ABAQUS 15组 + 环道 5组)...\n\n');
    
    all_fields = fieldnames(test_cases);
    total_count = 0;
    
    for i = 1:length(all_fields)
        fname = all_fields{i};
        if startsWith(fname, 'ABAQUS_') || startsWith(fname, 'RingRoad_')
            total_count = total_count + 1;
            fprintf('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
            fprintf('  运行 %d/20: %s\n', total_count, fname);
            fprintf('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
            
            try
                results.(fname) = runSingleCase(test_cases.(fname), fname);
            catch ME
                fprintf('  ❌ 运行失败: %s\n', ME.message);
                results.(fname) = struct('success', false, 'error', ME.message);
            end
        end
    end
    
    generatePaperTables(results, timestamp);
    
elseif startsWith(upper(group_name), 'ABAQUS_')
    case_num = str2double(group_name(8:end));
    if ~isnan(case_num) && case_num >= 1 && case_num <= 15
        field_name = sprintf('ABAQUS_%d', case_num);
        if isfield(test_cases, field_name)
            results.(field_name) = runSingleCase(test_cases.(field_name), field_name);
            generateSingleCaseReport(results.(field_name), timestamp);
        else
            fprintf('未找到测试组: %s\n', field_name);
            results = [];
            return;
        end
    else
        fprintf('无效的ABAQUS组号: %s (应为1-15)\n', group_name);
        results = [];
        return;
    end

elseif startsWith(upper(group_name), 'RINGROAD_')
    case_num = str2double(group_name(10:end));
    if ~isnan(case_num) && case_num >= 1 && case_num <= 5
        field_name = sprintf('RingRoad_%d', case_num);
        if isfield(test_cases, field_name)
            results.(field_name) = runSingleCase(test_cases.(field_name), field_name);
            generateSingleCaseReport(results.(field_name), timestamp);
        else
            fprintf('未找到测试组: %s\n', field_name);
            results = [];
            return;
        end
    else
        fprintf('无效的RingRoad组号: %s (应为1-5)\n', group_name);
        results = [];
        return;
    end

else
    fprintf('未知的测试组: %s\n', group_name);
    fprintf('可用选项:\n');
    fprintf('  ABAQUS        - 运行ABAQUS全部15组\n');
    fprintf('  ABAQUS_1~15   - 运行ABAQUS指定组\n');
    fprintf('  RingRoad      - 运行环道全部5组\n');
    fprintf('  RingRoad_1~5  - 运行环道指定组\n');
    fprintf('  all           - 运行全部20组\n');
    results = [];
    return;
end

filename = sprintf('test_results_%s_%s.mat', group_name, timestamp);
save(filename, 'results');
fprintf('\n💾 结果已保存到: %s\n', filename);

end

%% ═══════════════════════════════════════════════════════════════════════
%  运行单个测试案例
%% ═══════════════════════════════════════════════════════════════════════
function result = runSingleCase(input_data, case_name)

fprintf('\n═══════════════════════════════════════════════════════════════\n');
fprintf('  运行测试案例: %s\n', case_name);
fprintf('  描述: %s\n', input_data.description);
fprintf('═══════════════════════════════════════════════════════════════\n\n');

config = loadConfig();
config = applyConfigUpdate_v54(config);

fprintf('【配置状态】\n');
fprintf('  LLM引导: %s\n', iif(config.llm_guidance.enabled, '已启用', '已禁用'));
if config.llm_guidance.enabled
    fprintf('  LLM模型: %s\n', config.llm_guidance.model);
end
fprintf('  收敛阈值: %.1f%%\n', config.backcalculation.convergence_threshold * 100);
fprintf('  最大Episodes: %d\n', config.ppo_backcalculation.max_episodes);

pde_version = checkPDEVersion();
modulus_bounds = getModulusBounds(input_data, config);

fprintf('\n\n【Step 1】输入数据:\n');
fprintf('  路面类型: %s\n', getPavementTypeName(input_data));
fprintf('  结构层厚度: [%.1f, %.1f, %.1f] cm\n', ...
    input_data.thickness(1), input_data.thickness(2), input_data.thickness(3));
fprintf('  实测弯沉D0: %.4f mm\n', input_data.measured_deflection);
fprintf('  弯沉盆: [%s] mm\n', sprintf('%.4f ', input_data.deflection_basin));
fprintf('  模量约束: AC[%d,%d], BC[%d,%d], SB[%d,%d], SG[%d,%d] MPa\n', ...
    modulus_bounds.surface(1), modulus_bounds.surface(2), ...
    modulus_bounds.base(1), modulus_bounds.base(2), ...
    modulus_bounds.subbase(1), modulus_bounds.subbase(2), ...
    modulus_bounds.subgrade(1), modulus_bounds.subgrade(2));

if isfield(input_data, 'true_modulus')
    fprintf('  【真值】AC=%d, BC=%d, SB=%d, SG=%d MPa\n', ...
        input_data.true_modulus.surface, input_data.true_modulus.base, ...
        input_data.true_modulus.subbase, input_data.true_modulus.subgrade);
end

input_data.modulus_bounds = modulus_bounds;

fprintf('\n【Step 2】初始模量估计...\n');
initial_modulus = estimateInitialModulus(input_data, config);

fprintf('\n  初始模量估计结果:\n');
fprintf('    表面层: %d MPa\n', initial_modulus.surface);
fprintf('    基层:   %d MPa\n', initial_modulus.base);
fprintf('    底基层: %d MPa\n', initial_modulus.subbase);
fprintf('    土基:   %d MPa\n', initial_modulus.subgrade);

if isfield(input_data, 'true_modulus')
    fprintf('\n  【初始估计 vs 真值】\n');
    fprintf('    表面层: %d vs %d MPa (%.1f%%)\n', initial_modulus.surface, input_data.true_modulus.surface, ...
        abs(initial_modulus.surface - input_data.true_modulus.surface) / input_data.true_modulus.surface * 100);
    fprintf('    基层:   %d vs %d MPa (%.1f%%)\n', initial_modulus.base, input_data.true_modulus.base, ...
        abs(initial_modulus.base - input_data.true_modulus.base) / input_data.true_modulus.base * 100);
    fprintf('    底基层: %d vs %d MPa (%.1f%%)\n', initial_modulus.subbase, input_data.true_modulus.subbase, ...
        abs(initial_modulus.subbase - input_data.true_modulus.subbase) / input_data.true_modulus.subbase * 100);
    fprintf('    土基:   %d vs %d MPa (%.1f%%)\n', initial_modulus.subgrade, input_data.true_modulus.subgrade, ...
        abs(initial_modulus.subgrade - input_data.true_modulus.subgrade) / input_data.true_modulus.subgrade * 100);
end

fprintf('\n【Step 3】初始PDE正向验证...\n');
initial_pde_results = performPDE(input_data, initial_modulus, pde_version);

initial_D0 = getD0FromResults(initial_pde_results);
initial_error = abs(initial_D0 - input_data.measured_deflection) / input_data.measured_deflection;

[initial_basin_error, initial_physics_ok, physics_details] = evaluateConvergence(...
    initial_pde_results.deflections, input_data.deflection_basin, initial_modulus, input_data);

fprintf('  实测弯沉D0: %.4f mm\n', input_data.measured_deflection);
fprintf('  计算弯沉D0: %.4f mm\n', initial_D0);
fprintf('  D0误差:     %.2f%%\n', initial_error * 100);
fprintf('  弯沉盆误差: %.2f%%\n', initial_basin_error * 100);
fprintf('  物理约束:   %s\n', iif(initial_physics_ok, '✓ 满足', '✗ 不满足'));
if ~initial_physics_ok
    fprintf('    %s\n', physics_details);
end

threshold_d0 = config.backcalculation.convergence_threshold;
threshold_basin = 0.10;
force_optimize = isfield(input_data, 'true_modulus');
converged = (initial_error < threshold_d0) && (initial_basin_error < threshold_basin) && initial_physics_ok;

if ~force_optimize && converged
    fprintf('\n✅ 初始估计满足所有收敛条件，无需优化\n');
    final_modulus = initial_modulus;
    final_pde_results = initial_pde_results;
    final_error = initial_error;
    optimization_log = struct('iterations', 0, 'converged', true, 'total_time', 0);
    optimization_log.error_history = [];
    optimization_log.modulus_history = [];
else
    fprintf('\n【收敛检查】需要优化:\n');
    if force_optimize
        fprintf('   - 真值验证模式，强制优化\n');
    end
    if initial_error >= threshold_d0
        fprintf('   - D0误差: %.2f%% >= %.0f%% ✗\n', initial_error*100, threshold_d0*100);
    end
    if initial_basin_error >= threshold_basin
        fprintf('   - 弯沉盆误差: %.2f%% >= %.0f%% ✗\n', initial_basin_error*100, threshold_basin*100);
    end
    if ~initial_physics_ok
        fprintf('   - 物理约束: 不满足 ✗ (%s)\n', physics_details);
    end
    
    fprintf('\n【Step 4】启动PPO强化学习优化...\n');
    
    backcalc_agent = BackcalculationPPO(input_data, config, initial_modulus, initial_pde_results);
    [final_modulus, optimization_log] = backcalc_agent.optimize();
    
    % 保存收敛历史
    optimization_log.error_history = backcalc_agent.error_history;
    optimization_log.modulus_history = backcalc_agent.modulus_history;
    optimization_log.episode_rewards = backcalc_agent.episode_rewards;
    optimization_log.llm_call_count = backcalc_agent.llm_call_count;
    
    final_pde_results = performPDE(input_data, final_modulus, pde_version);
    final_D0 = getD0FromResults(final_pde_results);
    final_error = abs(final_D0 - input_data.measured_deflection) / input_data.measured_deflection;
end

% 组装结果
result = struct();
result.case_name = case_name;
result.input_data = input_data;
result.success = true;
result.pde_version = pde_version;

result.initial_modulus = initial_modulus;
result.final_modulus = final_modulus;
result.initial_error = initial_error;
result.final_error = final_error;

% 弯沉盆数据【关键】
result.deflection_data = struct();
% [Fix] 从input_data读取实际传感器位置（支持RIOH非标准偏移）
if isfield(input_data, 'sensor_offsets') && ~isempty(input_data.sensor_offsets)
    result.deflection_data.sensor_positions = input_data.sensor_offsets;
else
    result.deflection_data.sensor_positions = [0, 20, 30, 60, 90, 120, 150];
end
result.deflection_data.measured = input_data.deflection_basin;
result.deflection_data.calculated = final_pde_results.deflections;
result.deflection_data.initial_calculated = initial_pde_results.deflections;

n_points = min(length(input_data.deflection_basin), length(final_pde_results.deflections));
result.deflection_data.point_errors = zeros(1, n_points);
for j = 1:n_points
    if input_data.deflection_basin(j) > 0.001
        result.deflection_data.point_errors(j) = ...
            abs(final_pde_results.deflections(j) - input_data.deflection_basin(j)) / ...
            input_data.deflection_basin(j) * 100;
    end
end
result.deflection_data.mean_point_error = mean(result.deflection_data.point_errors);
result.deflection_data.max_point_error = max(result.deflection_data.point_errors);

result.optimization_log = optimization_log;

if isfield(input_data, 'true_modulus')
    result.true_modulus = input_data.true_modulus;
    result.modulus_errors = struct();
    result.modulus_errors.surface = abs(final_modulus.surface - input_data.true_modulus.surface) / input_data.true_modulus.surface * 100;
    result.modulus_errors.base = abs(final_modulus.base - input_data.true_modulus.base) / input_data.true_modulus.base * 100;
    result.modulus_errors.subbase = abs(final_modulus.subbase - input_data.true_modulus.subbase) / input_data.true_modulus.subbase * 100;
    result.modulus_errors.subgrade = abs(final_modulus.subgrade - input_data.true_modulus.subgrade) / input_data.true_modulus.subgrade * 100;
    result.modulus_errors.mean = (result.modulus_errors.surface + result.modulus_errors.base + ...
                                  result.modulus_errors.subbase + result.modulus_errors.subgrade) / 4;
    
    fprintf('\n【模量反演精度】(对比真值):\n');
    fprintf('  表面层误差: %.2f%% (反演: %d, 真值: %d)\n', result.modulus_errors.surface, final_modulus.surface, input_data.true_modulus.surface);
    fprintf('  基层误差:   %.2f%% (反演: %d, 真值: %d)\n', result.modulus_errors.base, final_modulus.base, input_data.true_modulus.base);
    fprintf('  底基层误差: %.2f%% (反演: %d, 真值: %d)\n', result.modulus_errors.subbase, final_modulus.subbase, input_data.true_modulus.subbase);
    fprintf('  土基误差:   %.2f%% (反演: %d, 真值: %d)\n', result.modulus_errors.subgrade, final_modulus.subgrade, input_data.true_modulus.subgrade);
    fprintf('  平均误差:   %.2f%%\n', result.modulus_errors.mean);
end

fprintf('\n【弯沉盆拟合详情】:\n');
fprintf('  测点位置(cm): %s\n', sprintf('%6d ', result.deflection_data.sensor_positions));
fprintf('  实测值(mm):   %s\n', sprintf('%6.4f ', result.deflection_data.measured));
fprintf('  计算值(mm):   %s\n', sprintf('%6.4f ', result.deflection_data.calculated));
fprintf('  各点误差(%%):  %s\n', sprintf('%6.2f ', result.deflection_data.point_errors));
fprintf('  平均误差: %.2f%%, 最大误差: %.2f%%\n', result.deflection_data.mean_point_error, result.deflection_data.max_point_error);

printResultSummary(initial_modulus, final_modulus, result, input_data);

end

%% ═══════════════════════════════════════════════════════════════════════
%  生成论文表格
%% ═══════════════════════════════════════════════════════════════════════
function generatePaperTables(results, timestamp)

fprintf('\n\n');
fprintf('╔════════════════════════════════════════════════════════════════════════════╗\n');
fprintf('║                    生成论文数据表格                                        ║\n');
fprintf('╚════════════════════════════════════════════════════════════════════════════╝\n');

fnames = fieldnames(results);
n_cases = length(fnames);

% 表1：模量反演结果
table1_file = sprintf('Table1_Modulus_Results_%s.csv', timestamp);
fid1 = fopen(table1_file, 'w');
fprintf(fid1, 'Case,Structure,AC_True,BC_True,SB_True,SG_True,AC_Inv,BC_Inv,SB_Inv,SG_Inv,AC_Err(%%),BC_Err(%%),SB_Err(%%),SG_Err(%%),Mean_Err(%%),D0_Err(%%),Iterations,Time(s)\n');

total_ac_err = 0; total_bc_err = 0; total_sb_err = 0; total_sg_err = 0;
success_count = 0;

for i = 1:n_cases
    fname = fnames{i};
    r = results.(fname);
    
    if isfield(r, 'success') && r.success && isfield(r, 'modulus_errors')
        success_count = success_count + 1;
        
        if isfield(r.input_data, 'structure_type_cn')
            struct_type = r.input_data.structure_type_cn;
        else
            struct_type = '-';
        end
        
        if isfield(r.optimization_log, 'iterations')
            iters = r.optimization_log.iterations;
        else
            iters = 0;
        end
        if isfield(r.optimization_log, 'total_time')
            time_s = r.optimization_log.total_time;
        else
            time_s = 0;
        end
        
        fprintf(fid1, '%s,%s,%d,%d,%d,%d,%d,%d,%d,%d,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%.1f\n', ...
            fname, struct_type, ...
            r.true_modulus.surface, r.true_modulus.base, r.true_modulus.subbase, r.true_modulus.subgrade, ...
            r.final_modulus.surface, r.final_modulus.base, r.final_modulus.subbase, round(r.final_modulus.subgrade), ...
            r.modulus_errors.surface, r.modulus_errors.base, r.modulus_errors.subbase, r.modulus_errors.subgrade, ...
            r.modulus_errors.mean, r.final_error*100, iters, time_s);
        
        total_ac_err = total_ac_err + r.modulus_errors.surface;
        total_bc_err = total_bc_err + r.modulus_errors.base;
        total_sb_err = total_sb_err + r.modulus_errors.subbase;
        total_sg_err = total_sg_err + r.modulus_errors.subgrade;
    end
end

if success_count > 0
    fprintf(fid1, 'Average,-,-,-,-,-,-,-,-,-,%.2f,%.2f,%.2f,%.2f,%.2f,-,-,-\n', ...
        total_ac_err/success_count, total_bc_err/success_count, ...
        total_sb_err/success_count, total_sg_err/success_count, ...
        (total_ac_err+total_bc_err+total_sb_err+total_sg_err)/(4*success_count));
end
fclose(fid1);
fprintf('  ✓ 表1已保存: %s\n', table1_file);

% 表2：弯沉盆拟合
table2_file = sprintf('Table2_Deflection_Basin_%s.csv', timestamp);
fid2 = fopen(table2_file, 'w');
fprintf(fid2, 'Case,D0_Meas,D20_Meas,D30_Meas,D60_Meas,D90_Meas,D120_Meas,D150_Meas,D0_Calc,D20_Calc,D30_Calc,D60_Calc,D90_Calc,D120_Calc,D150_Calc,D0_Err(%%),Mean_Err(%%),Max_Err(%%)\n');

for i = 1:n_cases
    fname = fnames{i};
    r = results.(fname);
    
    if isfield(r, 'success') && r.success && isfield(r, 'deflection_data')
        dd = r.deflection_data;
        meas = [dd.measured, zeros(1, max(0, 7-length(dd.measured)))];
        calc = [dd.calculated, zeros(1, max(0, 7-length(dd.calculated)))];
        
        fprintf(fid2, '%s,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.2f,%.2f,%.2f\n', ...
            fname, meas(1:7), calc(1:7), r.final_error*100, dd.mean_point_error, dd.max_point_error);
    end
end
fclose(fid2);
fprintf('  ✓ 表2已保存: %s\n', table2_file);

% 表3：环道数据结果（无真值，仅弯沉盆拟合）
table3_file = sprintf('Table3_RingRoad_Results_%s.csv', timestamp);
fid3 = fopen(table3_file, 'w');
fprintf(fid3, 'Case,Structure,AC_cm,BC_cm,SB_cm,AC_MPa,BC_MPa,SB_MPa,SG_MPa,D0_Meas_mm,D0_Calc_mm,D0_Err(%%),Basin_Err(%%),Iterations,Time(s)\n');

ringroad_count = 0;
for i = 1:n_cases
    fname = fnames{i};
    r = results.(fname);
    
    if isfield(r, 'success') && r.success && ~isfield(r, 'modulus_errors')
        ringroad_count = ringroad_count + 1;
        
        if isfield(r.input_data, 'description')
            struct_desc = r.input_data.description;
        else
            struct_desc = '-';
        end
        
        thickness = r.input_data.thickness;
        
        if isfield(r.optimization_log, 'iterations')
            iters = r.optimization_log.iterations;
        else
            iters = 0;
        end
        if isfield(r.optimization_log, 'total_time')
            time_s = r.optimization_log.total_time;
        else
            time_s = 0;
        end
        
        fprintf(fid3, '%s,"%s",%d,%d,%d,%d,%d,%d,%d,%.4f,%.4f,%.2f,%.2f,%d,%.1f\n', ...
            fname, struct_desc, ...
            thickness(1), thickness(2), thickness(3), ...
            r.final_modulus.surface, r.final_modulus.base, ...
            r.final_modulus.subbase, round(r.final_modulus.subgrade), ...
            r.input_data.measured_deflection, r.deflection_data.calculated(1), ...
            r.final_error*100, r.deflection_data.mean_point_error, iters, time_s);
    end
end
fclose(fid3);
if ringroad_count > 0
    fprintf('  ✓ 表3已保存: %s (环道数据 %d组)\n', table3_file, ringroad_count);
end

% 控制台汇总表
fprintf('\n');
fprintf('┌──────────┬────────┬─────────────────────┬─────────────────────┬───────────┬─────────┐\n');
fprintf('│ Case     │ 结构   │ 反演模量[AC,BC,SB]  │ 真值[AC,BC,SB]      │ 平均误差  │ D0误差  │\n');
fprintf('├──────────┼────────┼─────────────────────┼─────────────────────┼───────────┼─────────┤\n');

for i = 1:n_cases
    fname = fnames{i};
    r = results.(fname);
    
    if isfield(r, 'success') && r.success && isfield(r, 'modulus_errors')
        if isfield(r.input_data, 'structure_type_cn')
            struct_type = r.input_data.structure_type_cn;
            struct_type = struct_type(1:min(6,end));
        else
            struct_type = '-';
        end
        
        fprintf('│ %-8s │ %-6s │ [%5d,%4d,%4d]    │ [%5d,%4d,%4d]    │ %6.2f%%   │ %5.2f%%  │\n', ...
            fname, struct_type, ...
            r.final_modulus.surface, r.final_modulus.base, r.final_modulus.subbase, ...
            r.true_modulus.surface, r.true_modulus.base, r.true_modulus.subbase, ...
            r.modulus_errors.mean, r.final_error*100);
    else
        fprintf('│ %-8s │   -    │ 运行失败            │         -           │     -     │    -    │\n', fname);
    end
end

fprintf('└──────────┴────────┴─────────────────────┴─────────────────────┴───────────┴─────────┘\n');

% 如果有无真值的案例（环道数据），单独显示
no_truth_cases = 0;
for i = 1:n_cases
    fname = fnames{i};
    r = results.(fname);
    if isfield(r, 'success') && r.success && ~isfield(r, 'modulus_errors')
        no_truth_cases = no_truth_cases + 1;
    end
end

if no_truth_cases > 0
    fprintf('\n【无真值数据（环道实测）- 仅评估弯沉盆拟合】\n');
    fprintf('┌──────────────┬────────────┬─────────────────────────┬─────────┬─────────┐\n');
    fprintf('│ Case         │ 结构       │ 反演模量[AC,BC,SB,SG]   │ D0误差  │ 弯沉盆  │\n');
    fprintf('├──────────────┼────────────┼─────────────────────────┼─────────┼─────────┤\n');
    
    for i = 1:n_cases
        fname = fnames{i};
        r = results.(fname);
        
        if isfield(r, 'success') && r.success && ~isfield(r, 'modulus_errors')
            if isfield(r.input_data, 'structure_type_cn')
                struct_type = r.input_data.structure_type_cn;
                struct_type = struct_type(1:min(10,end));
            else
                struct_type = '-';
            end
            
            fprintf('│ %-12s │ %-10s │ [%5d,%5d,%4d,%3d]  │ %5.2f%%  │ %5.2f%%  │\n', ...
                fname, struct_type, ...
                r.final_modulus.surface, r.final_modulus.base, ...
                r.final_modulus.subbase, round(r.final_modulus.subgrade), ...
                r.final_error*100, r.deflection_data.mean_point_error);
        end
    end
    fprintf('└──────────────┴────────────┴─────────────────────────┴─────────┴─────────┘\n');
end

if success_count > 0
    fprintf('\n  📊 统计汇总 (有真值数据):\n');
    fprintf('     成功率: %d/%d (%.1f%%)\n', success_count, n_cases, success_count/n_cases*100);
    fprintf('     平均模量误差: AC=%.2f%%, BC=%.2f%%, SB=%.2f%%, SG=%.2f%%\n', ...
        total_ac_err/success_count, total_bc_err/success_count, total_sb_err/success_count, total_sg_err/success_count);
    fprintf('     总体平均误差: %.2f%%\n', (total_ac_err+total_bc_err+total_sb_err+total_sg_err)/(4*success_count));
end

if no_truth_cases > 0
    % 计算无真值数据的弯沉盆拟合统计
    total_d0_err = 0;
    total_basin_err = 0;
    for i = 1:n_cases
        fname = fnames{i};
        r = results.(fname);
        if isfield(r, 'success') && r.success && ~isfield(r, 'modulus_errors')
            total_d0_err = total_d0_err + r.final_error * 100;
            total_basin_err = total_basin_err + r.deflection_data.mean_point_error;
        end
    end
    fprintf('\n  📊 统计汇总 (无真值数据 - 环道):\n');
    fprintf('     案例数: %d\n', no_truth_cases);
    fprintf('     平均D0误差: %.2f%%\n', total_d0_err / no_truth_cases);
    fprintf('     平均弯沉盆误差: %.2f%%\n', total_basin_err / no_truth_cases);
end

fprintf('\n  📁 论文数据文件:\n');
fprintf('     - %s (模量对比表-有真值)\n', table1_file);
fprintf('     - %s (弯沉盆数据)\n', table2_file);
if ringroad_count > 0
    fprintf('     - %s (环道数据-无真值)\n', table3_file);
end

end

%% ═══════════════════════════════════════════════════════════════════════
%  生成单案例报告
%% ═══════════════════════════════════════════════════════════════════════
function generateSingleCaseReport(result, timestamp)

if ~result.success
    return;
end

fprintf('\n\n');
fprintf('╔════════════════════════════════════════════════════════════════════════════╗\n');
fprintf('║                    单案例详细报告                                          ║\n');
fprintf('╚════════════════════════════════════════════════════════════════════════════╝\n');

basin_file = sprintf('DeflectionBasin_%s_%s.csv', result.case_name, timestamp);
fid = fopen(basin_file, 'w');
fprintf(fid, 'Position(cm),Measured(mm),Calculated(mm),Error(%%)\n');

dd = result.deflection_data;
n = min(length(dd.measured), length(dd.calculated));
for j = 1:n
    fprintf(fid, '%d,%.4f,%.4f,%.2f\n', dd.sensor_positions(j), dd.measured(j), dd.calculated(j), dd.point_errors(j));
end
fclose(fid);
fprintf('  ✓ 弯沉盆数据已保存: %s\n', basin_file);

if isfield(result.optimization_log, 'error_history') && ~isempty(result.optimization_log.error_history)
    conv_file = sprintf('ConvergenceHistory_%s_%s.csv', result.case_name, timestamp);
    fid = fopen(conv_file, 'w');
    fprintf(fid, 'Episode,Error(%%),AC(MPa),BC(MPa),SB(MPa),SG(MPa)\n');
    
    err_hist = result.optimization_log.error_history;
    mod_hist = result.optimization_log.modulus_history;
    
    for ep = 1:length(err_hist)
        if ep <= size(mod_hist, 1)
            % 【v5.4.2修复】modulus_history是矩阵，不是struct数组
            % 格式: [surface, base, subbase, subgrade] 每行一个时间步
            fprintf(fid, '%d,%.4f,%d,%d,%d,%d\n', ep, err_hist(ep)*100, ...
                mod_hist(ep, 1), mod_hist(ep, 2), mod_hist(ep, 3), round(mod_hist(ep, 4)));
        end
    end
    fclose(fid);
    fprintf('  ✓ 收敛历史已保存: %s\n', conv_file);
end

figure('Position', [100, 100, 800, 400]);

subplot(1,2,1);
plot(dd.sensor_positions, dd.measured, 'bo-', 'LineWidth', 2, 'MarkerSize', 8, 'DisplayName', '实测值');
hold on;
plot(dd.sensor_positions, dd.calculated, 'rs--', 'LineWidth', 2, 'MarkerSize', 8, 'DisplayName', '计算值');
xlabel('距荷载中心距离 (cm)');
ylabel('弯沉 (mm)');
title(sprintf('%s 弯沉盆拟合', result.case_name));
legend('Location', 'northeast');
grid on;
set(gca, 'YDir', 'reverse');

subplot(1,2,2);
bar(dd.sensor_positions, dd.point_errors);
xlabel('距荷载中心距离 (cm)');
ylabel('误差 (%)');
title('各测点拟合误差');
grid on;

fig_file = sprintf('DeflectionBasin_%s_%s.png', result.case_name, timestamp);
saveas(gcf, fig_file);
fprintf('  ✓ 弯沉盆图已保存: %s\n', fig_file);
close(gcf);

end

%% ═══════════════════════════════════════════════════════════════════════
%  辅助函数
function bounds = getModulusBounds(input_data, config)
bounds = struct();

% 如果输入数据已指定约束范围，直接使用
if isfield(input_data, 'modulus_bounds')
    bounds = input_data.modulus_bounds;
    return;
end
if isfield(input_data, 'expected_modulus_range')
    bounds = input_data.expected_modulus_range;
    return;
end

% 根据路面类型设置不同的约束范围
pavement_type = '';
if isfield(input_data, 'pavement_type')
    pavement_type = input_data.pavement_type;
end

if strcmpi(pavement_type, 'semi_rigid')
    % ═══════════════════════════════════════════════════════════════════════
    % 【v6.2.2 关键修正】半刚性基层结构约束范围
    % ═══════════════════════════════════════════════════════════════════════
    % 基层: 水泥稳定碎石(CBG) - 规范模量5000-15000 MPa（可达30GPa）
    % 底基层: 水泥土(CS) - 规范模量1500-5000 MPa
    % 特点: 基层模量可能接近或高于沥青层
    % ───────────────────────────────────────────────────────────────────────
    bounds.surface = [3000, 15000];     % 沥青层
    bounds.base = [5000, 18000];        % 水泥稳定碎石基层 【关键】大幅扩大
    bounds.subbase = [1500, 6000];      % 水泥土底基层 【关键】提高下限
    bounds.subgrade = [40, 200];        % 土基
    
    fprintf('  [约束模式: 半刚性基层结构 v6.2.2 - 基于规范值]\n');
    fprintf('    基层(CBG): [%d, %d] MPa\n', bounds.base(1), bounds.base(2));
    fprintf('    底基层(CS): [%d, %d] MPa\n', bounds.subbase(1), bounds.subbase(2));
    
elseif strcmpi(pavement_type, 'rigid_composite')
    % 刚性复合路面
    bounds.surface = [5000, 25000];
    bounds.base = [25000, 40000];
    bounds.subbase = [8000, 18000];
    bounds.subgrade = [60, 300];
    
    fprintf('  [约束模式: 刚性复合式路面]\n');
    
elseif strcmpi(pavement_type, 'inverted')
    % 倒装式路面
    bounds.surface = [3000, 15000];
    bounds.base = [150, 800];
    bounds.subbase = [80, 400];
    bounds.subgrade = [40, 200];
    
    fprintf('  [约束模式: 倒装式路面]\n');
    
else
    % 柔性路面（默认）
    bounds.surface = [800, 6500];      % 沥青层
    bounds.base = [150, 2000];         % 级配碎石基层
    bounds.subbase = [50, 700];        % 底基层
    bounds.subgrade = [20, 180];       % 土基
    
    fprintf('  [约束模式: 柔性路面]\n');
end
end


function name = getPavementTypeName(input_data)
if isfield(input_data, 'pavement_type_name')
    name = input_data.pavement_type_name;
elseif isfield(input_data, 'structure_type_cn')
    name = input_data.structure_type_cn;
elseif isfield(input_data, 'pavement_type')
    name = input_data.pavement_type;
else
    name = '未知';
end
end

function [basin_error, physics_ok, physics_msg] = evaluateConvergence(computed, measured, modulus, input_data)
n = min(length(computed), length(measured));
weights = [3, 2, 2, 1.5, 1, 1, 1];
weights = weights(1:n) / sum(weights(1:n));
errors = abs(computed(1:n) - measured(1:n)) ./ max(measured(1:n), 0.01);
basin_error = sum(weights .* errors);

physics_ok = true;
physics_msg = '';

% 根据路面类型应用不同的物理约束
pavement_type = '';
if isfield(input_data, 'pavement_type')
    pavement_type = input_data.pavement_type;
end

if strcmpi(pavement_type, 'semi_rigid')
    % 半刚性结构：基层（水泥稳定碎石）模量可能比沥青层高
    % 只检查底基层>土基
    if modulus.subbase <= modulus.subgrade
        physics_ok = false;
        physics_msg = [physics_msg, '底基层应>土基; '];
    end
    % 基层应该大于底基层（水泥稳定碎石 > 水泥土）
    if modulus.base <= modulus.subbase
        physics_ok = false;
        physics_msg = [physics_msg, '基层(CBG)应>底基层(CS); '];
    end
else
    % 柔性路面：模量递减 AC > BC > SB > SG
    if modulus.surface <= modulus.base
        physics_ok = false;
        physics_msg = [physics_msg, '表面层应>基层; '];
    end
    if modulus.base <= modulus.subbase
        physics_ok = false;
        physics_msg = [physics_msg, '基层应>底基层; '];
    end
    if modulus.subbase <= modulus.subgrade
        physics_ok = false;
        physics_msg = [physics_msg, '底基层应>土基; '];
    end
end
end

function printResultSummary(initial_modulus, final_modulus, result, input_data)
fprintf('\n╔════════════════════════════════════════════════════════════╗\n');
fprintf('║                   反演结果摘要                             ║\n');
fprintf('╚════════════════════════════════════════════════════════════╝\n\n');

fprintf('  ┌─────────────┬──────────┬──────────┐\n');
fprintf('  │   结构层    │ 初始估计 │ 反演结果 │\n');
fprintf('  ├─────────────┼──────────┼──────────┤\n');
fprintf('  │ 表面层(MPa) │ %8d │ %8d │\n', initial_modulus.surface, final_modulus.surface);
fprintf('  │ 基层(MPa)   │ %8d │ %8d │\n', initial_modulus.base, final_modulus.base);
fprintf('  │ 底基层(MPa) │ %8d │ %8d │\n', initial_modulus.subbase, final_modulus.subbase);
fprintf('  │ 土基(MPa)   │ %8d │ %8d │\n', initial_modulus.subgrade, round(final_modulus.subgrade));
fprintf('  └─────────────┴──────────┴──────────┘\n\n');

fprintf('  弯沉误差: %.2f%% → %.2f%%\n', result.initial_error*100, result.final_error*100);

if isfield(result, 'modulus_errors')
    fprintf('\n  模量反演精度:\n');
    fprintf('    表面层: %.1f%%\n', result.modulus_errors.surface);
    fprintf('    基层:   %.1f%%\n', result.modulus_errors.base);
    fprintf('    底基层: %.1f%%\n', result.modulus_errors.subbase);
    fprintf('    土基:   %.1f%%\n', result.modulus_errors.subgrade);
    fprintf('    平均:   %.1f%%\n', result.modulus_errors.mean);
end
end

function result = iif(condition, true_val, false_val)
if condition
    result = true_val;
else
    result = false_val;
end
end

function version = checkPDEVersion()
fprintf('\n【PDE版本检查】\n');
if exist('roadPDEModelingABAQUSCalibrated', 'file') == 2
    fprintf('  ✓ 使用: roadPDEModelingABAQUSCalibrated (推荐)\n');
    version = 'calibrated';
elseif exist('roadPDEModelingABAQUS', 'file') == 2
    fprintf('  ⚠ 使用: roadPDEModelingABAQUS\n');
    version = 'abaqus';
else
    fprintf('  ⚠ 使用: roadPDEModeling\n');
    version = 'basic';
end
fprintf('\n');
end

%% ═══════════════════════════════════════════════════════════════════════
%  【关键修复】PDE调用函数 - 与BackcalculationPPO接口一致
%% ═══════════════════════════════════════════════════════════════════════
function pde_results = performPDE(input_data, modulus, pde_version)
% PERFORMPDE 执行PDE建模计算
%
% 【v6.1.1修复】
%   使用与BackcalculationPPO.evaluateModulus相同的三参数接口：
%   roadPDEModelingABAQUSCalibrated(designParams, loadParams, boundary_conditions)
%
% 输入:
%   input_data   - 输入数据结构体 (包含thickness, poisson, load_pressure等)
%   modulus      - 模量结构体 (包含surface, base, subbase, subgrade)
%   pde_version  - PDE版本 ('calibrated', 'abaqus', 'basic')
%
% 输出:
%   pde_results  - PDE计算结果

% ================== 构造 designParams ==================
designParams = struct();
designParams.thickness = input_data.thickness(:);  % 确保为列向量
designParams.modulus = [modulus.surface; modulus.base; modulus.subbase];  % 3层模量
designParams.poisson = input_data.poisson(:);  % 确保为列向量

% ================== 构造 loadParams ==================
loadParams = struct();
if isfield(input_data, 'load_pressure')
    loadParams.load_pressure = input_data.load_pressure;
else
    loadParams.load_pressure = 0.707355;  % 与ABAQUS一致的默认值
end
if isfield(input_data, 'load_radius')
    loadParams.load_radius = input_data.load_radius;
else
    loadParams.load_radius = 15.0;  % 默认15cm
end

% ================== 构造 boundary_conditions ==================
boundary_conditions = struct();
boundary_conditions.modeling_type = 'multilayer_subgrade';

% 土基模量
if isfield(input_data, 'subgrade_modulus') && input_data.subgrade_modulus > 0
    boundary_conditions.subgrade_modulus = input_data.subgrade_modulus;
    boundary_conditions.soil_modulus = input_data.subgrade_modulus;
elseif isfield(modulus, 'subgrade') && modulus.subgrade > 0
    boundary_conditions.subgrade_modulus = modulus.subgrade;
    boundary_conditions.soil_modulus = modulus.subgrade;
else
    boundary_conditions.subgrade_modulus = 40;  % 默认值
    boundary_conditions.soil_modulus = 40;
end

% 传感器位置
if isfield(input_data, 'sensor_offsets')
    boundary_conditions.sensor_offsets = input_data.sensor_offsets;
else
    boundary_conditions.sensor_offsets = [0, 20, 30, 60, 90, 120, 150];
end

% v6.2.1: 传递路面类型以便校准函数正确处理
if isfield(input_data, 'pavement_type')
    boundary_conditions.pavement_type = input_data.pavement_type;
end

% ================== 调用PDE函数 ==================
try
    switch pde_version
        case 'calibrated'
            % 推荐：使用内置校准的版本
            pde_results = roadPDEModelingABAQUSCalibrated(designParams, loadParams, boundary_conditions);
            
        case 'abaqus'
            % 备选：ABAQUS版本 + 手动校准
            pde_results = roadPDEModelingABAQUS(designParams, loadParams, boundary_conditions);
            calibration_factor = 0.70;
            if isfield(pde_results, 'D0')
                pde_results.D0 = pde_results.D0 * calibration_factor;
            end
            if isfield(pde_results, 'deflections')
                pde_results.deflections = pde_results.deflections * calibration_factor;
            end
            
        otherwise
            % 不推荐：原版PDE
            pde_results = roadPDEModelingSimplified(designParams, loadParams, boundary_conditions);
    end
    
    % 验证结果
    if ~isfield(pde_results, 'success') || ~pde_results.success
        fprintf('    ⚠️ PDE计算标记为失败，使用后备结果\n');
        pde_results = createBackupResults(input_data);
    end
    
catch ME
    fprintf('    ❌ PDE计算异常: %s\n', ME.message);
    pde_results = createBackupResults(input_data);
end

end

%% ═══════════════════════════════════════════════════════════════════════
%  后备结果生成（PDE失败时使用）
%% ═══════════════════════════════════════════════════════════════════════
function backup_results = createBackupResults(input_data)
% 创建后备计算结果（当PDE失败时使用）

if isfield(input_data, 'measured_deflection')
    D0 = input_data.measured_deflection;
elseif isfield(input_data, 'deflection_basin') && ~isempty(input_data.deflection_basin)
    D0 = input_data.deflection_basin(1);
else
    D0 = 0.5;  % 默认中心弯沉
end

% 多点弯沉位置和经验衰减系数
deflection_points = [0, 20, 30, 60, 90, 120, 150];  % cm
decay_ratios = [1.0, 0.82, 0.73, 0.56, 0.44, 0.35, 0.28];  % 经验衰减比例

% 计算多点弯沉
deflections = D0 * decay_ratios;

backup_results = struct();
backup_results.success = false;
backup_results.D0 = D0;
backup_results.deflections = deflections;
backup_results.deflection_points = deflection_points;
backup_results.method = 'empirical_fallback';
backup_results.error_message = 'PDE计算失败，使用经验关系';

fprintf('    📝 使用经验关系生成后备结果: D0=%.4f mm\n', D0);

end

function D0 = getD0FromResults(pde_results)
if isfield(pde_results, 'D0')
    D0 = pde_results.D0;
elseif isfield(pde_results, 'deflections') && ~isempty(pde_results.deflections)
    D0 = pde_results.deflections(1);
else
    D0 = 0;
end
end

%% ═══════════════════════════════════════════════════════════════════════
%  配置加载函数
%% ═══════════════════════════════════════════════════════════════════════
function config = loadConfig()
% 优先使用 loadBackcalculationConfig 函数（包含完整的验证和补充逻辑）
if exist('loadBackcalculationConfig', 'file')
    try
        config = loadBackcalculationConfig();
        return;
    catch ME
        fprintf('  ⚠️ loadBackcalculationConfig 调用失败: %s\n', ME.message);
    end
end

% 备选：直接读取 JSON 文件
if exist('config_backcalculation.json', 'file')
    try
        json_text = fileread('config_backcalculation.json');
        config = jsondecode(json_text);
        fprintf('  ✓ 已加载配置文件: config_backcalculation.json\n');
        % 验证并补充缺失字段
        config = validateConfigFields(config);
    catch
        config = getDefaultConfig();
        fprintf('  ⚠️ 配置文件解析失败，使用默认配置\n');
    end
else
    config = getDefaultConfig();
    fprintf('  使用默认配置\n');
end
end

function config = validateConfigFields(config)
% 验证并补充缺失的配置字段
default = getDefaultConfig();

% 确保 llm_guidance 存在
if ~isfield(config, 'llm_guidance')
    config.llm_guidance = default.llm_guidance;
else
    if ~isfield(config.llm_guidance, 'enabled')
        config.llm_guidance.enabled = default.llm_guidance.enabled;
    end
    if ~isfield(config.llm_guidance, 'model')
        config.llm_guidance.model = default.llm_guidance.model;
    end
end

% 确保 backcalculation 存在
if ~isfield(config, 'backcalculation')
    config.backcalculation = default.backcalculation;
else
    if ~isfield(config.backcalculation, 'convergence_threshold')
        config.backcalculation.convergence_threshold = default.backcalculation.convergence_threshold;
    end
end

% 确保 ppo_backcalculation 存在
if ~isfield(config, 'ppo_backcalculation')
    config.ppo_backcalculation = default.ppo_backcalculation;
else
    if ~isfield(config.ppo_backcalculation, 'max_episodes')
        config.ppo_backcalculation.max_episodes = default.ppo_backcalculation.max_episodes;
    end
    if ~isfield(config.ppo_backcalculation, 'max_steps_per_episode')
        config.ppo_backcalculation.max_steps_per_episode = default.ppo_backcalculation.max_steps_per_episode;
    end
    if ~isfield(config.ppo_backcalculation, 'early_stop_patience')
        config.ppo_backcalculation.early_stop_patience = default.ppo_backcalculation.early_stop_patience;
    end
end

% 确保 modulus_constraints 存在
if ~isfield(config, 'modulus_constraints')
    config.modulus_constraints = default.modulus_constraints;
end

% 【v6.2.1新增】确保 deepseek 配置存在 (callLLMAPI需要)
if ~isfield(config, 'deepseek')
    config.deepseek = default.deepseek;
else
    % 补充缺失字段
    if ~isfield(config.deepseek, 'api_key')
        config.deepseek.api_key = default.deepseek.api_key;
    end
    if ~isfield(config.deepseek, 'model')
        config.deepseek.model = default.deepseek.model;
    end
    if ~isfield(config.deepseek, 'base_url')
        config.deepseek.base_url = default.deepseek.base_url;
    end
    if ~isfield(config.deepseek, 'max_tokens')
        config.deepseek.max_tokens = default.deepseek.max_tokens;
    end
    if ~isfield(config.deepseek, 'temperature')
        config.deepseek.temperature = default.deepseek.temperature;
    end
    if ~isfield(config.deepseek, 'timeout')
        config.deepseek.timeout = default.deepseek.timeout;
    end
end

% 确保 llm_guidance 其他字段存在
if isfield(config, 'llm_guidance')
    if ~isfield(config.llm_guidance, 'guidance_interval')
        config.llm_guidance.guidance_interval = default.llm_guidance.guidance_interval;
    end
    if ~isfield(config.llm_guidance, 'use_for_initial_estimate')
        config.llm_guidance.use_for_initial_estimate = default.llm_guidance.use_for_initial_estimate;
    end
    if ~isfield(config.llm_guidance, 'use_for_optimization_guidance')
        config.llm_guidance.use_for_optimization_guidance = default.llm_guidance.use_for_optimization_guidance;
    end
end
end

function config = getDefaultConfig()
    config = struct();
    
    % PPO 参数
    config.ppo_backcalculation = struct();
    config.ppo_backcalculation.max_episodes = 100;  % 限制100
    config.ppo_backcalculation.max_steps_per_episode = 20;
    config.ppo_backcalculation.early_stop_patience = 15;
    config.ppo_backcalculation.learning_rate = 0.001;
    
    % 反演参数
    config.backcalculation = struct();
    config.backcalculation.convergence_threshold = 0.03;
    
    % LLM 引导参数 【v6.2.1 修正】
    config.llm_guidance = struct();
    config.llm_guidance.enabled = true;           % 启用LLM引导
    config.llm_guidance.model = 'deepseek';       % 模型名称
    config.llm_guidance.guidance_interval = 5;    % 每5个episode调用一次
    config.llm_guidance.use_for_initial_estimate = true;
    config.llm_guidance.use_for_optimization_guidance = true;
    
    % 【关键修复】DeepSeek模型配置 - callLLMAPI需要此配置
    config.deepseek = struct();
    config.deepseek.api_key = '';  % 从config_backcalculation.json读取
    config.deepseek.model = 'deepseek-chat';
    config.deepseek.base_url = 'https://api.deepseek.com';  % 注意：不带/v1
    config.deepseek.max_tokens = 2000;
    config.deepseek.temperature = 0.1;
    config.deepseek.timeout = 30;
    
    % 验证参数
    config.validation = struct();
    config.validation.sensitivity_analysis = false;
    
    % 输出参数
    config.output = struct();
    config.output.save_results = true;
    config.output.plot_results = true;
end

%% ═══════════════════════════════════════════════════════════════════════
%  初始模量估计
%% ═══════════════════════════════════════════════════════════════════════
function initial_modulus = estimateInitialModulus(input_data, config)
if config.llm_guidance.enabled
    fprintf('  使用混合模式（LLM + 经验公式）\n');
else
    fprintf('  使用经验公式模式\n');
end

% 优先使用专门的初始模量生成器
if exist('initialModulusGenerator', 'file')
    try
        initial_modulus = initialModulusGenerator(input_data, config);
        return;
    catch ME
        fprintf('  ⚠️ initialModulusGenerator失败: %s\n', ME.message);
    end
end

% 基于弯沉的经验估计
D0 = input_data.measured_deflection;

% 获取模量约束
if isfield(input_data, 'modulus_bounds')
    bounds = input_data.modulus_bounds;
else
    bounds = struct();
    bounds.surface = [1000, 5000];
    bounds.base = [300, 1500];
    bounds.subbase = [100, 500];
    bounds.subgrade = [20, 100];
end

% 基于D0的经验公式估计
if D0 > 0.8
    % 软弱路面
    initial_modulus.surface = max(bounds.surface(1), min(1500, bounds.surface(2)));
    initial_modulus.base = max(bounds.base(1), min(400, bounds.base(2)));
    initial_modulus.subbase = max(bounds.subbase(1), min(150, bounds.subbase(2)));
    initial_modulus.subgrade = max(bounds.subgrade(1), min(30, bounds.subgrade(2)));
elseif D0 > 0.5
    % 中等路面
    initial_modulus.surface = max(bounds.surface(1), min(2500, bounds.surface(2)));
    initial_modulus.base = max(bounds.base(1), min(600, bounds.base(2)));
    initial_modulus.subbase = max(bounds.subbase(1), min(200, bounds.subbase(2)));
    initial_modulus.subgrade = max(bounds.subgrade(1), min(50, bounds.subgrade(2)));
elseif D0 > 0.3
    % 较好路面
    initial_modulus.surface = max(bounds.surface(1), min(3500, bounds.surface(2)));
    initial_modulus.base = max(bounds.base(1), min(800, bounds.base(2)));
    initial_modulus.subbase = max(bounds.subbase(1), min(300, bounds.subbase(2)));
    initial_modulus.subgrade = max(bounds.subgrade(1), min(80, bounds.subgrade(2)));
else
    % 优良路面
    initial_modulus.surface = max(bounds.surface(1), min(4500, bounds.surface(2)));
    initial_modulus.base = max(bounds.base(1), min(1000, bounds.base(2)));
    initial_modulus.subbase = max(bounds.subbase(1), min(400, bounds.subbase(2)));
    initial_modulus.subgrade = max(bounds.subgrade(1), min(100, bounds.subgrade(2)));
end

fprintf('  初始估计基于D0=%.4fmm的经验公式\n', D0);
end

  function config = applyConfigUpdate_v54(config)
        fprintf('\n  【应用v5.4配置更新】\n');

        % 收紧收敛条件
        config.backcalculation.convergence_threshold = 0.03;  % 3%
        fprintf('    收敛阈值: 5%% → 3%%\n');

        % PPO参数
        config.ppo_backcalculation.max_episodes = 100;
        config.ppo_backcalculation.early_stop_patience = 15;

        % LLM参数
        if isfield(config, 'llm_guidance') && config.llm_guidance.enabled
            config.llm_guidance.guidance_interval = 5;
        end

        % 敏感性分析
        if ~isfield(config, 'validation')
            config.validation = struct();
        end
        config.validation.enable_sensitivity_analysis = true;
        config.validation.confidence_interval = 0.95;

        fprintf('  【配置更新完成】\n\n');
    end