%% runAblationStudy_v2_4.m - 消融实验自动化脚本（v2.4 字段名修复版）
%
% 修复内容（v2.4）：
%   - 【关键修复】修复变体名称中'/'字符导致的无效字段名问题
%   - 添加 makeValidFieldName 辅助函数将非法字符转换为下划线
%   - 修复 computeStatistics 和 generateSummaryText 中的字段名使用
%
% 修复内容（v2.3）：
%   - 修复恢复模式下旧结果与新结果字段不匹配的关键问题
%   - 自动检测并补全旧结果中缺失的字段
%   - 确保所有result结构字段完全一致
%
% 修复内容（v2.2）：
%   - 修复恢复模式下的variants结构体初始化错误
%   - 使用逐字段赋值避免结构体不匹配
%
% 修复内容（v2.1）：
%   - 修复LLM API失败时的错误处理
%   - 修复结构体字段不匹配问题
%   - 增加LLM失败后自动降级到经验公式
%   - 增加从中断处继续运行的功能
%
% 使用方法：
%   results = runAblationStudy_v2_4();  % 全新运行
%   results = runAblationStudy_v2_4('AblationResults_Temp_*.mat');  % 继续运行
%
% 版本: v2.4 - 字段名修复版
% 日期：2025-12-17

function results = runAblationStudy_v2_4(resume_file)

fprintf('\n');
fprintf('╔════════════════════════════════════════════════════════════╗\n');
fprintf('║   消融实验自动化脚本 v2.4 (字段名修复版)                  ║\n');
fprintf('║   - 修复变体名称中/字符导致的字段名问题 ✅               ║\n');
fprintf('║   - 修复旧结果字段不匹配问题 ✅                            ║\n');
fprintf('║   - 支持中断后继续运行                                     ║\n');
fprintf('╚════════════════════════════════════════════════════════════╝\n\n');

%% ═══════════════════════════════════════════════════════════════════════
%  0. 检查是否从中断处继续
%% ═══════════════════════════════════════════════════════════════════════

resume_mode = false;
if nargin > 0 && ~isempty(resume_file) && exist(resume_file, 'file')
    fprintf('【恢复模式】从临时文件继续运行: %s\n', resume_file);
    load(resume_file, 'results');
    resume_mode = true;
    
    % 显示已完成的运行
    completed = sum([results.runs.success] | ~[results.runs.success]);
    fprintf('  已完成运行数: %d / %d\n', completed, results.metadata.total_runs);
    fprintf('  成功: %d, 失败: %d\n\n', sum([results.runs.success]), sum(~[results.runs.success]));
end

%% ═══════════════════════════════════════════════════════════════════════
%  1. 加载测试案例
%% ═══════════════════════════════════════════════════════════════════════

if ~resume_mode
    fprintf('【步骤1】加载测试案例...\n');
    
    % 验证必要函数存在
    if ~exist('loadTestCases', 'file')
        error('找不到 loadTestCases 函数！请确保在项目根目录运行。');
    end
    
    test_cases = loadTestCases();
    
    % 选择6组代表性案例（与论文一致）
    selected_cases = {'ABAQUS_1', 'ABAQUS_2', 'ABAQUS_4', 'ABAQUS_5', 'ABAQUS_7', 'ABAQUS_13'};
    fprintf('  选定案例: %s\n', strjoin(selected_cases, ', '));
    
    % 验证案例存在
    for i = 1:length(selected_cases)
        if ~isfield(test_cases, selected_cases{i})
            error('案例 %s 不存在于 loadTestCases() 中！', selected_cases{i});
        end
    end
    
    fprintf('  ✓ 所有案例验证通过\n');
else
    % 恢复模式：从保存的数据中恢复
    test_cases = loadTestCases();
    selected_cases = results.metadata.selected_cases;
    fprintf('【步骤1】案例信息已从临时文件恢复\n');
end

%% ═══════════════════════════════════════════════════════════════════════
%  2. 定义4个变体配置
%% ═══════════════════════════════════════════════════════════════════════

if ~resume_mode
    fprintf('\n【步骤2】定义消融实验变体...\n');
    
    variants = struct();
    
    % 变体1: Full (LLM-PPO)
    variants(1).name = 'Full';
    variants(1).display_name = 'LLM-PPO (Full)';
    variants(1).llm_enabled = true;
    variants(1).llm_init = true;
    variants(1).llm_guide = true;
    variants(1).init_method = 'llm';
    
    % 变体2: w/o LLM-Guide
    %variants(2).name = 'w/o_Guide';
    %variants(2).display_name = 'w/o LLM-Guide';
    %variants(2).llm_enabled = true;
    %variants(2).llm_init = true;
    %variants(2).llm_guide = false;
    %variants(2).init_method = 'llm';
    
    % 变体3: w/o LLM-Init
    %variants(3).name = 'w/o_Init';
    %variants(3).display_name = 'w/o LLM-Init';
    %variants(3).llm_enabled = true;
    %variants(3).llm_init = false;
    %variants(3).llm_guide = true;
    %variants(3).init_method = 'empirical';
    
    % 变体4: Pure PPO
    %variants(4).name = 'Pure_PPO';
    %variants(4).display_name = 'Pure PPO';
    %variants(4).llm_enabled = false;
    %variants(4).llm_init = false;
    %variants(4).llm_guide = false;
    %variants(4).init_method = 'empirical';
    
    fprintf('  定义的变体:\n');
    for i = 1:length(variants)
        fprintf('    %d. %-20s (LLM初估:%d, LLM引导:%d)\n', ...
            i, variants(i).display_name, variants(i).llm_init, variants(i).llm_guide);
    end
else
    % 恢复模式：重新构建变体定义（使用逐字段赋值避免结构体不匹配）
    fprintf('【步骤2】重新构建变体定义...\n');
    
    % 变体1: Full
    variants(1).name = 'Full';
    variants(1).display_name = 'LLM-PPO (Full)';
    variants(1).llm_enabled = true;
    variants(1).llm_init = true;
    variants(1).llm_guide = true;
    variants(1).init_method = 'llm';
    
    % 变体2: w/o LLM-Guide
    variants(2).name = 'w/o_Guide';
    variants(2).display_name = 'w/o LLM-Guide';
    variants(2).llm_enabled = true;
    variants(2).llm_init = true;
    variants(2).llm_guide = false;
    variants(2).init_method = 'llm';
    
    % 变体3: w/o LLM-Init
    variants(3).name = 'w/o_Init';
    variants(3).display_name = 'w/o LLM-Init';
    variants(3).llm_enabled = true;
    variants(3).llm_init = false;
    variants(3).llm_guide = true;
    variants(3).init_method = 'empirical';
    
    % 变体4: Pure PPO
    variants(4).name = 'Pure_PPO';
    variants(4).display_name = 'Pure PPO';
    variants(4).llm_enabled = false;
    variants(4).llm_init = false;
    variants(4).llm_guide = false;
    variants(4).init_method = 'empirical';
    
    fprintf('  ✓ 变体定义已重建\n');
end

%% ═══════════════════════════════════════════════════════════════════════
%  3. 加载基础配置
%% ═══════════════════════════════════════════════════════════════════════

if ~resume_mode
    fprintf('\n【步骤3】加载配置文件...\n');
    
    % 使用项目的loadConfig函数
    try
        base_config = loadConfig();
        fprintf('  ✓ 配置加载成功\n');
    catch ME
        error('配置加载失败: %s\n请确保 config_backcalculation.json 存在或定义了 loadConfig() 函数', ME.message);
    end
    
    % 验证关键配置字段
    required_fields = {'ppo_backcalculation', 'backcalculation', 'llm_guidance'};
    for i = 1:length(required_fields)
        if ~isfield(base_config, required_fields{i})
            error('配置缺少必要字段: %s', required_fields{i});
        end
    end
    
    fprintf('  ✓ 配置验证通过\n');
    fprintf('    - PPO最大Episodes: %d\n', base_config.ppo_backcalculation.max_episodes);
    fprintf('    - 收敛阈值: %.1f%%\n', base_config.backcalculation.convergence_threshold * 100);
else
    base_config = loadConfig();
    fprintf('【步骤3】配置文件已重新加载\n');
end

%% ═══════════════════════════════════════════════════════════════════════
%  4. 验证依赖函数
%% ═══════════════════════════════════════════════════════════════════════

if ~resume_mode
    fprintf('\n【步骤4】验证依赖函数...\n');
    
    required_functions = {
        'BackcalculationPPO', 
        'initialModulusGenerator', 
        'roadPDEModelingABAQUSCalibrated'
    };
    
    missing_functions = {};
    for i = 1:length(required_functions)
        if ~exist(required_functions{i}, 'file')
            missing_functions{end+1} = required_functions{i};
        end
    end
    
    if ~isempty(missing_functions)
        error('缺少必要函数: %s', strjoin(missing_functions, ', '));
    end
    
    fprintf('  ✓ 所有依赖函数验证通过\n');
else
    fprintf('【步骤4】跳过依赖检查（恢复模式）\n');
end

%% ═══════════════════════════════════════════════════════════════════════
%  5. 初始化结果存储
%% ═══════════════════════════════════════════════════════════════════════

if ~resume_mode
    fprintf('\n【步骤5】初始化结果存储结构...\n');
    
    % 创建结果结构
    results = struct();
    results.metadata = struct();
    results.metadata.timestamp = datestr(now, 'yyyymmdd_HHMMSS');
    results.metadata.selected_cases = selected_cases;
    results.metadata.num_cases = length(selected_cases);
    results.metadata.num_variants = length(variants);
    results.metadata.num_runs_per_case = 3;
    results.metadata.total_runs = length(selected_cases) * length(variants) * 3;
    results.metadata.start_time = now;
    
    % 预分配结果数组
    results.runs = [];
    
    fprintf('  预计总运行次数: %d (6案例 × 4变体 × 3次)\n', results.metadata.total_runs);
    fprintf('  预计总时间: %.1f-%.1f 小时 (假设每次30-60秒)\n', ...
        results.metadata.total_runs * 30 / 3600, results.metadata.total_runs * 60 / 3600);
    
    run_counter = 0;
    global_start_time = tic;
else
    fprintf('【步骤5】结果结构已从临时文件恢复\n');
    
    % 【关键修复】检查并统一旧结果的字段结构
    fprintf('  正在检查并修复旧结果的字段结构...\n');
    
    if ~isempty(results.runs)
        % 获取标准字段结构（所有字段的完整模板）
        standard_result = createEmptyResult();
        standard_fields = fieldnames(standard_result);
        
        % 修复每个旧结果的字段
        num_fixed = 0;
        for i = 1:length(results.runs)
            old_fields = fieldnames(results.runs(i));
            
            % 找到缺失的字段
            missing_fields = setdiff(standard_fields, old_fields);
            
            if ~isempty(missing_fields)
                % 添加缺失的字段（使用标准值）
                for j = 1:length(missing_fields)
                    field_name = missing_fields{j};
                    results.runs(i).(field_name) = standard_result.(field_name);
                end
                num_fixed = num_fixed + 1;
            end
        end
        
        if num_fixed > 0
            fprintf('  ✓ 已修复 %d 个旧结果（添加缺失字段）\n', num_fixed);
        else
            fprintf('  ✓ 所有旧结果字段结构正常\n');
        end
    end
    
    run_counter = length(results.runs);
    global_start_time = tic;  % 重新开始计时
end

%% ═══════════════════════════════════════════════════════════════════════
%  6. 主循环：遍历所有变体、案例、运行次数
%% ═══════════════════════════════════════════════════════════════════════

fprintf('\n【步骤6】开始消融实验主循环...\n\n');

total_runs = results.metadata.total_runs;

% 【新增】创建已完成任务的标记
completed_tasks = containers.Map('KeyType', 'char', 'ValueType', 'logical');
if resume_mode
    for i = 1:length(results.runs)
        task_key = sprintf('%s_%s_R%d', ...
            results.runs(i).case_name, ...
            results.runs(i).variant_name, ...
            results.runs(i).run_number);
        completed_tasks(task_key) = true;
    end
end

for v = 1:length(variants)
    variant = variants(v);
    
    fprintf('\n');
    fprintf('════════════════════════════════════════════════════════════════\n');
    fprintf('  变体 %d/%d: %s\n', v, length(variants), variant.display_name);
    fprintf('  配置: LLM初估=%d, LLM引导=%d, 初始方法=%s\n', ...
        variant.llm_init, variant.llm_guide, variant.init_method);
    fprintf('════════════════════════════════════════════════════════════════\n');
    
    for c = 1:length(selected_cases)
        case_name = selected_cases{c};
        input_data = test_cases.(case_name);
        
        fprintf('\n  ┌────────────────────────────────────────────────────────┐\n');
        fprintf('  │ 案例 %d/%d: %-15s D0=%.4f mm  AC=%dcm   │\n', ...
            c, length(selected_cases), case_name, ...
            input_data.measured_deflection, input_data.thickness(1));
        fprintf('  └────────────────────────────────────────────────────────┘\n\n');
        
        for r = 1:3  % 每个案例运行3次
            % 【新增】检查任务是否已完成
            task_key = sprintf('%s_%s_R%d', case_name, variant.name, r);
            if resume_mode && isKey(completed_tasks, task_key)
                fprintf('    ⏭️  跳过已完成的任务: %s × %s × Run#%d\n\n', ...
                    variant.display_name, case_name, r);
                continue;
            end
            
            run_counter = run_counter + 1;
            
            % 计算进度
            progress = run_counter / total_runs * 100;
            elapsed_total = toc(global_start_time);
            if run_counter > 1
                avg_time = elapsed_total / run_counter;
                remaining_time = avg_time * (total_runs - run_counter);
            else
                remaining_time = 0;
            end
            
            fprintf('    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
            fprintf('    运行 %d/%d (%.1f%%)  |  已用时 %.1fmin  |  预计剩余 %.1fmin\n', ...
                run_counter, total_runs, progress, elapsed_total/60, remaining_time/60);
            fprintf('    %s × %s × Run#%d\n', variant.display_name, case_name, r);
            fprintf('    ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n');
            
            try
                % 配置当前变体
                config = configureVariant(base_config, variant);
                
                % 运行单次实验
                run_result = runSingleExperiment(input_data, config, case_name, variant, r);
                
                % 存储结果
                results.runs = [results.runs; run_result];
                
                fprintf('    ✓ 运行成功！\n');
                fprintf('      D0误差: %.2f%%  |  模量误差: %.2f%%  |  迭代: %d  |  耗时: %.1fs\n', ...
                    run_result.D0_error * 100, run_result.mean_modulus_error * 100, ...
                    run_result.iterations, run_result.time);
                fprintf('      反演模量: [%d, %d, %d, %d] MPa\n', ...
                    round(run_result.E_AC), round(run_result.E_BC), ...
                    round(run_result.E_SB), round(run_result.E_SG));
                
                if ~run_result.converged
                    fprintf('      ⚠️  未收敛至%.1f%%阈值（实际%.2f%%）\n', ...
                        config.backcalculation.convergence_threshold*100, run_result.D0_error*100);
                end
                fprintf('\n');
                
            catch ME
                fprintf('    ❌ 运行失败: %s\n', ME.message);
                if ~isempty(ME.stack)
                    fprintf('       堆栈: %s (行%d)\n\n', ME.stack(1).name, ME.stack(1).line);
                end
                
                % 【修复】记录失败信息 - 使用完整的字段结构
                failed_result = createEmptyResult();
                failed_result.case_name = case_name;
                failed_result.variant_name = variant.name;
                failed_result.variant_display_name = variant.display_name;
                failed_result.run_number = r;
                failed_result.success = false;
                failed_result.error_message = ME.message;
                if ~isempty(ME.stack)
                    failed_result.error_stack = sprintf('%s:%d', ME.stack(1).name, ME.stack(1).line);
                else
                    failed_result.error_stack = 'Unknown';
                end
                
                results.runs = [results.runs; failed_result];
            end
            
            % 中间保存（每5次运行或每个案例结束）
            if mod(run_counter, 5) == 0 || r == 3
                temp_filename = sprintf('AblationResults_Temp_%s.mat', results.metadata.timestamp);
                save(temp_filename, 'results');
                if mod(run_counter, 5) == 0
                    fprintf('    💾 中间进度已保存: %s\n\n', temp_filename);
                end
            end
        end
    end
end

%% ═══════════════════════════════════════════════════════════════════════
%  7. 数据分析和统计
%% ═══════════════════════════════════════════════════════════════════════

fprintf('\n【步骤7】分析结果数据...\n');

results.metadata.end_time = now;
results.metadata.total_elapsed_time = toc(global_start_time);

results.statistics = computeStatistics(results.runs, variants, selected_cases);

fprintf('  ✓ 统计分析完成\n');
fprintf('    成功率: %.1f%% (%d/%d)\n', ...
    results.statistics.success_rate*100, ...
    results.statistics.successful_runs, ...
    results.statistics.total_runs);

%% ═══════════════════════════════════════════════════════════════════════
%  8. 生成输出文件
%% ═══════════════════════════════════════════════════════════════════════

fprintf('\n【步骤8】生成输出文件...\n');

timestamp = results.metadata.timestamp;

% 保存完整结果
mat_filename = sprintf('AblationResults_%s.mat', timestamp);
save(mat_filename, 'results');
fprintf('  ✓ 完整结果已保存: %s\n', mat_filename);

% 生成CSV表格
csv_filename = sprintf('AblationTable_%s.csv', timestamp);
generateAblationTableCSV(results, csv_filename, variants);
fprintf('  ✓ 论文表格已生成: %s\n', csv_filename);

% 生成统计汇总
summary_filename = sprintf('AblationSummary_%s.txt', timestamp);
generateSummaryText(results, summary_filename, variants);
fprintf('  ✓ 统计汇总已生成: %s\n', summary_filename);

% 删除临时文件
temp_files = dir(sprintf('AblationResults_Temp_%s.mat', timestamp));
if ~isempty(temp_files)
    delete(temp_files.name);
    fprintf('  ✓ 临时文件已清理\n');
end

%% ═══════════════════════════════════════════════════════════════════════
%  9. 打印最终摘要
%% ═══════════════════════════════════════════════════════════════════════

fprintf('\n');
fprintf('╔════════════════════════════════════════════════════════════╗\n');
fprintf('║   消融实验完成！                                           ║\n');
fprintf('╠════════════════════════════════════════════════════════════╣\n');
fprintf('║  总运行次数: %d                                            ║\n', run_counter);
fprintf('║  成功: %d  |  失败: %d                                     ║\n', ...
    sum([results.runs.success]), sum(~[results.runs.success]));
fprintf('║  总耗时: %.1f 小时                                         ║\n', ...
    results.metadata.total_elapsed_time / 3600);
fprintf('║                                                            ║\n');
fprintf('║  输出文件:                                                 ║\n');
fprintf('║    📊 %s\n', mat_filename);
fprintf('║    📋 %s\n', csv_filename);
fprintf('║    📄 %s\n', summary_filename);
fprintf('╚════════════════════════════════════════════════════════════╝\n\n');

% 打印关键统计
fprintf('【关键结果摘要】\n');
variant_names = fieldnames(results.statistics.by_variant);
for i = 1:length(variant_names)
    vname = variant_names{i};
    vstats = results.statistics.by_variant.(vname);
    
    % 找到对应的display_name
    display_name = vname;
    for v = 1:length(variants)
        % 【修复】使用 makeValidFieldName 进行比较
        if strcmp(makeValidFieldName(variants(v).name), vname)
            display_name = variants(v).display_name;
            break;
        end
    end
    
    fprintf('  %-20s: D₀=%.2f±%.2f%%  |  模量=%.1f±%.1f%%  |  迭代=%.1f  |  时间=%.1fs\n', ...
        display_name, ...
        vstats.D0_error_mean*100, vstats.D0_error_std*100, ...
        vstats.modulus_error_mean*100, vstats.modulus_error_std*100, ...
        vstats.iterations_mean, vstats.time_mean);
end

fprintf('\n提示: 使用以下命令查看详细结果:\n');
fprintf('  load(''%s'');\n', mat_filename);
fprintf('  readtable(''%s'');\n', csv_filename);
fprintf('\n');

end

%% ═══════════════════════════════════════════════════════════════════════
%  辅助函数
%% ═══════════════════════════════════════════════════════════════════════

function valid_name = makeValidFieldName(name)
% 【v2.4新增】将字符串转换为有效的MATLAB结构体字段名
%
% 功能：
%   - 将斜杠 '/' 替换为下划线 '_'
%   - 将其他非法字符也替换为下划线
%   - 确保名称以字母开头
%
% 输入：
%   name - 原始名称字符串
%
% 输出：
%   valid_name - 有效的MATLAB字段名

% 替换斜杠为下划线
valid_name = strrep(name, '/', '_');

% 替换其他可能的非法字符（空格、连字符等）
valid_name = strrep(valid_name, ' ', '_');
valid_name = strrep(valid_name, '-', '_');
valid_name = strrep(valid_name, '.', '_');

% 使用 matlab.lang.makeValidName 进行最终验证（如果可用）
if exist('matlab.lang.makeValidName', 'builtin') || exist('matlab.lang.makeValidName', 'file')
    valid_name = matlab.lang.makeValidName(valid_name);
end

end

function empty_result = createEmptyResult()
% 【新增】创建空结果结构，确保字段完整一致

empty_result = struct();
empty_result.case_name = '';
empty_result.variant_name = '';
empty_result.variant_display_name = '';
empty_result.run_number = 0;
empty_result.success = false;

% 模量结果
empty_result.E_AC = NaN;
empty_result.E_BC = NaN;
empty_result.E_SB = NaN;
empty_result.E_SG = NaN;

% 真实模量
empty_result.True_E_AC = NaN;
empty_result.True_E_BC = NaN;
empty_result.True_E_SB = NaN;
empty_result.True_E_SG = NaN;

% 误差指标
empty_result.D0_error = NaN;
empty_result.basin_mean_error = NaN;
empty_result.E_AC_error = NaN;
empty_result.E_BC_error = NaN;
empty_result.E_SB_error = NaN;
empty_result.E_SG_error = NaN;
empty_result.mean_modulus_error = NaN;

% 性能指标
empty_result.iterations = 0;
empty_result.time = 0;
empty_result.converged = false;
empty_result.llm_call_count = 0;

% 弯沉盆
empty_result.measured_basin = [];
empty_result.calculated_basin = [];

% 历史数据
empty_result.error_history = [];

% 错误信息
empty_result.error_message = '';
empty_result.error_stack = '';

end

function config = configureVariant(base_config, variant)
% 根据变体定义配置LLM参数

config = base_config;

% 设置LLM总开关
config.llm_guidance.enabled = variant.llm_enabled;

% 设置LLM初始估计
config.llm_guidance.use_for_initial_estimate = variant.llm_init;

% 设置LLM中间引导
config.llm_guidance.use_for_optimization_guidance = variant.llm_guide;

end

function result = runSingleExperiment(input_data, config, case_name, variant, run_number)
% 运行单次实验

% 1. 生成初始模量（使用项目的initialModulusGenerator）
% 【修复】增加LLM失败时的降级处理
try
    initial_modulus = initialModulusGenerator(input_data, config, variant.init_method);
    
    fprintf('      初始模量估计 (method=%s): [%d, %d, %d, %d] MPa\n', ...
        variant.init_method, ...
        round(initial_modulus.surface), round(initial_modulus.base), ...
        round(initial_modulus.subbase), round(initial_modulus.subgrade));
        
catch ME
    % LLM失败时自动降级到经验公式
    if contains(ME.message, 'LLM') || contains(ME.message, 'API')
        fprintf('      ⚠️ LLM初始估计失败，自动降级到经验公式\n');
        fprintf('         错误: %s\n', ME.message);
        
        % 使用经验公式
        initial_modulus = empiricalInitialEstimate(input_data);
        fprintf('      经验公式估计: [%d, %d, %d, %d] MPa\n', ...
            round(initial_modulus.surface), round(initial_modulus.base), ...
            round(initial_modulus.subbase), round(initial_modulus.subgrade));
    else
        % 其他错误直接抛出
        rethrow(ME);
    end
end

% 2. 计算初始PDE结果
initial_pde_results = computeInitialPDE(input_data, initial_modulus);

fprintf('      初始D0: %.4f mm (目标: %.4f mm, 误差: %.2f%%)\n', ...
    initial_pde_results.D0, input_data.measured_deflection, ...
    abs(initial_pde_results.D0 - input_data.measured_deflection) / input_data.measured_deflection * 100);

% 3. 创建PPO实例
ppo = BackcalculationPPO(input_data, config, initial_modulus, initial_pde_results);

% 4. 执行优化
run_start_time = tic;
[final_modulus, optimization_log] = ppo.optimize();
elapsed_time = toc(run_start_time);

% 5. 计算最终PDE结果
final_pde = computeFinalPDE(input_data, final_modulus);

% 6. 计算误差指标
D0_error = abs(final_pde.D0 - input_data.measured_deflection) / input_data.measured_deflection;
basin_errors = abs(final_pde.deflections - input_data.deflection_basin) ./ input_data.deflection_basin;
basin_mean_error = mean(basin_errors);

% 7. 计算模量误差（如果有真值）
if isfield(input_data, 'true_modulus')
    true_mod = input_data.true_modulus;
    modulus_errors = [
        abs(final_modulus.surface - true_mod.surface) / true_mod.surface;
        abs(final_modulus.base - true_mod.base) / true_mod.base;
        abs(final_modulus.subbase - true_mod.subbase) / true_mod.subbase;
        abs(final_modulus.subgrade - true_mod.subgrade) / true_mod.subgrade
    ];
    mean_modulus_error = mean(modulus_errors);
else
    modulus_errors = [NaN; NaN; NaN; NaN];
    mean_modulus_error = NaN;
end

% 8. 整理结果
result = struct();
result.case_name = case_name;
result.variant_name = variant.name;
result.variant_display_name = variant.display_name;
result.run_number = run_number;
result.success = true;

% 模量结果
result.E_AC = final_modulus.surface;
result.E_BC = final_modulus.base;
result.E_SB = final_modulus.subbase;
result.E_SG = final_modulus.subgrade;

% 真实模量（如果有）
if isfield(input_data, 'true_modulus')
    result.True_E_AC = true_mod.surface;
    result.True_E_BC = true_mod.base;
    result.True_E_SB = true_mod.subbase;
    result.True_E_SG = true_mod.subgrade;
else
    result.True_E_AC = NaN;
    result.True_E_BC = NaN;
    result.True_E_SB = NaN;
    result.True_E_SG = NaN;
end

% 误差指标
result.D0_error = D0_error;
result.basin_mean_error = basin_mean_error;
result.E_AC_error = modulus_errors(1);
result.E_BC_error = modulus_errors(2);
result.E_SB_error = modulus_errors(3);
result.E_SG_error = modulus_errors(4);
result.mean_modulus_error = mean_modulus_error;

% 性能指标
result.iterations = optimization_log.iterations;
result.time = elapsed_time;
result.converged = optimization_log.converged;

% LLM调用次数
if isfield(optimization_log, 'llm_call_count')
    result.llm_call_count = optimization_log.llm_call_count;
else
    result.llm_call_count = 0;
end

% 弯沉盆
result.measured_basin = input_data.deflection_basin;
result.calculated_basin = final_pde.deflections;

% 历史数据
result.error_history = optimization_log.error_history;

% 错误信息（成功时为空）
result.error_message = '';
result.error_stack = '';

end

function initial_modulus = empiricalInitialEstimate(input_data)
% 【新增】基于弯沉的经验公式初始估计（LLM失败时的备用方案）

D0 = input_data.measured_deflection;

% 根据D0估计模量（简化版，与initialModulusGenerator的经验公式一致）
if D0 > 0.5
    % 超柔性路面
    initial_modulus.surface = 1500;
    initial_modulus.base = 400;
    initial_modulus.subbase = 150;
    initial_modulus.subgrade = 30;
elseif D0 > 0.35
    % 柔性路面
    initial_modulus.surface = 2500;
    initial_modulus.base = 600;
    initial_modulus.subbase = 200;
    initial_modulus.subgrade = 50;
elseif D0 > 0.20
    % 中等刚度路面
    initial_modulus.surface = 3500;
    initial_modulus.base = 800;
    initial_modulus.subbase = 300;
    initial_modulus.subgrade = 80;
else
    % 刚性路面
    initial_modulus.surface = 4500;
    initial_modulus.base = 1000;
    initial_modulus.subbase = 400;
    initial_modulus.subgrade = 100;
end

end

function pde_results = computeInitialPDE(input_data, initial_modulus)
% 计算初始PDE结果

designParams = struct();
designParams.thickness = input_data.thickness(:);
designParams.modulus = [initial_modulus.surface; initial_modulus.base; initial_modulus.subbase];
designParams.poisson = input_data.poisson(:);

loadParams = struct();
loadParams.load_pressure = input_data.load_pressure;
loadParams.load_radius = input_data.load_radius;

boundary_conditions = struct();
boundary_conditions.modeling_type = 'multilayer_subgrade';
boundary_conditions.subgrade_modulus = initial_modulus.subgrade;
boundary_conditions.soil_modulus = initial_modulus.subgrade;
boundary_conditions.sensor_offsets = input_data.sensor_offsets;

if isfield(input_data, 'pavement_type')
    boundary_conditions.pavement_type = input_data.pavement_type;
end

pde_results = roadPDEModelingABAQUSCalibrated(designParams, loadParams, boundary_conditions);

end

function pde_results = computeFinalPDE(input_data, final_modulus)
% 计算最终PDE结果（与computeInitialPDE相同逻辑）

designParams = struct();
designParams.thickness = input_data.thickness(:);
designParams.modulus = [final_modulus.surface; final_modulus.base; final_modulus.subbase];
designParams.poisson = input_data.poisson(:);

loadParams = struct();
loadParams.load_pressure = input_data.load_pressure;
loadParams.load_radius = input_data.load_radius;

boundary_conditions = struct();
boundary_conditions.modeling_type = 'multilayer_subgrade';
boundary_conditions.subgrade_modulus = final_modulus.subgrade;
boundary_conditions.soil_modulus = final_modulus.subgrade;
boundary_conditions.sensor_offsets = input_data.sensor_offsets;

if isfield(input_data, 'pavement_type')
    boundary_conditions.pavement_type = input_data.pavement_type;
end

pde_results = roadPDEModelingABAQUSCalibrated(designParams, loadParams, boundary_conditions);

end

function stats = computeStatistics(runs, variants, selected_cases)
% 计算统计汇总

stats = struct();

% 提取成功的运行
successful_runs = runs([runs.success]);

if isempty(successful_runs)
    warning('没有成功的运行！');
    stats.success_rate = 0;
    stats.total_runs = length(runs);
    stats.successful_runs = 0;
    return;
end

stats.success_rate = length(successful_runs) / length(runs);
stats.total_runs = length(runs);
stats.successful_runs = length(successful_runs);

% 按变体统计
stats.by_variant = struct();

for v = 1:length(variants)
    variant_name = variants(v).name;
    variant_runs = successful_runs(strcmp({successful_runs.variant_name}, variant_name));
    
    if ~isempty(variant_runs)
        % 【v2.4关键修复】使用 makeValidFieldName 转换字段名
        valid_field_name = makeValidFieldName(variant_name);
        
        stats.by_variant.(valid_field_name) = struct();
        stats.by_variant.(valid_field_name).D0_error_mean = mean([variant_runs.D0_error]);
        stats.by_variant.(valid_field_name).D0_error_std = std([variant_runs.D0_error]);
        stats.by_variant.(valid_field_name).basin_error_mean = mean([variant_runs.basin_mean_error]);
        stats.by_variant.(valid_field_name).basin_error_std = std([variant_runs.basin_mean_error]);
        stats.by_variant.(valid_field_name).modulus_error_mean = mean([variant_runs.mean_modulus_error], 'omitnan');
        stats.by_variant.(valid_field_name).modulus_error_std = std([variant_runs.mean_modulus_error], 'omitnan');
        stats.by_variant.(valid_field_name).iterations_mean = mean([variant_runs.iterations]);
        stats.by_variant.(valid_field_name).iterations_std = std([variant_runs.iterations]);
        stats.by_variant.(valid_field_name).time_mean = mean([variant_runs.time]);
        stats.by_variant.(valid_field_name).time_std = std([variant_runs.time]);
        stats.by_variant.(valid_field_name).convergence_rate = sum([variant_runs.converged]) / length(variant_runs);
    end
end

% 按案例统计
stats.by_case = struct();

for c = 1:length(selected_cases)
    case_name = selected_cases{c};
    case_runs = successful_runs(strcmp({successful_runs.case_name}, case_name));
    
    if ~isempty(case_runs)
        stats.by_case.(case_name) = struct();
        stats.by_case.(case_name).D0_error_mean = mean([case_runs.D0_error]);
        stats.by_case.(case_name).D0_error_std = std([case_runs.D0_error]);
        stats.by_case.(case_name).modulus_error_mean = mean([case_runs.mean_modulus_error], 'omitnan');
        stats.by_case.(case_name).num_runs = length(case_runs);
    end
end

end

function generateAblationTableCSV(results, filename, variants)
% 生成论文格式的CSV表格

fid = fopen(filename, 'w');

% 写入表头
fprintf(fid, 'Case,Variant,Run,E_AC,E_BC,E_SB,E_SG,True_E_AC,True_E_BC,True_E_SB,True_E_SG,');
fprintf(fid, 'D0_Err_pct,Basin_Err_pct,E_AC_Err_pct,E_BC_Err_pct,E_SB_Err_pct,E_SG_Err_pct,');
fprintf(fid, 'Mean_Modulus_Err_pct,Iterations,Time_s,Converged,LLM_Calls\n');

% 写入数据
successful_runs = results.runs([results.runs.success]);

for i = 1:length(successful_runs)
    r = successful_runs(i);
    fprintf(fid, '%s,%s,%d,%d,%d,%d,%d,%d,%d,%d,%d,', ...
        r.case_name, r.variant_display_name, r.run_number, ...
        round(r.E_AC), round(r.E_BC), round(r.E_SB), round(r.E_SG), ...
        round(r.True_E_AC), round(r.True_E_BC), round(r.True_E_SB), round(r.True_E_SG));
    fprintf(fid, '%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%.1f,%d,%d\n', ...
        r.D0_error*100, r.basin_mean_error*100, ...
        r.E_AC_error*100, r.E_BC_error*100, r.E_SB_error*100, r.E_SG_error*100, ...
        r.mean_modulus_error*100, ...
        r.iterations, r.time, r.converged, r.llm_call_count);
end

fclose(fid);

end

function generateSummaryText(results, filename, variants)
% 生成统计汇总文本

fid = fopen(filename, 'w');

fprintf(fid, '════════════════════════════════════════════════════════════\n');
fprintf(fid, '  消融实验统计汇总\n');
fprintf(fid, '  生成时间: %s\n', datestr(now));
fprintf(fid, '════════════════════════════════════════════════════════════\n\n');

fprintf(fid, '实验配置:\n');
fprintf(fid, '  案例数: %d\n', results.metadata.num_cases);
fprintf(fid, '  案例列表: %s\n', strjoin(results.metadata.selected_cases, ', '));
fprintf(fid, '  变体数: %d\n', results.metadata.num_variants);
fprintf(fid, '  每组重复: %d次\n', results.metadata.num_runs_per_case);
fprintf(fid, '  总运行次数: %d\n', results.metadata.total_runs);
fprintf(fid, '  总耗时: %.2f 小时\n', results.metadata.total_elapsed_time / 3600);
fprintf(fid, '\n');

fprintf(fid, '运行结果:\n');
fprintf(fid, '  成功: %d / %d (%.1f%%)\n', results.statistics.successful_runs, ...
    results.statistics.total_runs, results.statistics.success_rate*100);
fprintf(fid, '\n');

fprintf(fid, '按变体统计 (Mean ± Std):\n');
fprintf(fid, '─────────────────────────────────────────────────────────────────────────────────\n');
fprintf(fid, '%-20s | D0误差(%%)    | 弯沉盆误差(%%) | 模量误差(%%)  | 迭代次数   | 时间(s) | 收敛率\n', 'Variant');
fprintf(fid, '─────────────────────────────────────────────────────────────────────────────────\n');

for v = 1:length(variants)
    % 【v2.4关键修复】使用 makeValidFieldName 获取有效字段名
    vname = makeValidFieldName(variants(v).name);
    if isfield(results.statistics.by_variant, vname)
        vstats = results.statistics.by_variant.(vname);
        fprintf(fid, '%-20s | %5.2f±%-5.2f | %5.2f±%-6.2f | %5.1f±%-5.1f | %5.1f±%-4.1f | %6.1f | %.1f%%\n', ...
            variants(v).display_name, ...
            vstats.D0_error_mean*100, vstats.D0_error_std*100, ...
            vstats.basin_error_mean*100, vstats.basin_error_std*100, ...
            vstats.modulus_error_mean*100, vstats.modulus_error_std*100, ...
            vstats.iterations_mean, vstats.iterations_std, ...
            vstats.time_mean, vstats.convergence_rate*100);
    end
end

fprintf(fid, '\n');

fprintf(fid, '按案例统计:\n');
fprintf(fid, '────────────────────────────────────────────────\n');
fprintf(fid, '%-15s | D0误差(%%)    | 模量误差(%%)  | 运行次数\n', 'Case');
fprintf(fid, '────────────────────────────────────────────────\n');

case_names = fieldnames(results.statistics.by_case);
for i = 1:length(case_names)
    cname = case_names{i};
    cstats = results.statistics.by_case.(cname);
    fprintf(fid, '%-15s | %5.2f±%-5.2f | %5.1f±%-5.1f | %d\n', ...
        cname, ...
        cstats.D0_error_mean*100, cstats.D0_error_std*100, ...
        cstats.modulus_error_mean*100, 0.0, ...
        cstats.num_runs);
end

fprintf(fid, '\n');
fprintf(fid, '════════════════════════════════════════════════════════════\n');
fprintf(fid, '  实验完成！\n');
fprintf(fid, '════════════════════════════════════════════════════════════\n');

fclose(fid);

end

%% ═══════════════════════════════════════════════════════════════════════
%  工具函数 (来自runTestCases.m)
%% ═══════════════════════════════════════════════════════════════════════

function config = loadConfig()
% 优先使用 loadBackcalculationConfig 函数
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

if ~isfield(config, 'llm_guidance')
    config.llm_guidance = default.llm_guidance;
else
    if ~isfield(config.llm_guidance, 'enabled')
        config.llm_guidance.enabled = default.llm_guidance.enabled;
    end
    if ~isfield(config.llm_guidance, 'use_for_initial_estimate')
        config.llm_guidance.use_for_initial_estimate = true;
    end
    if ~isfield(config.llm_guidance, 'use_for_optimization_guidance')
        config.llm_guidance.use_for_optimization_guidance = true;
    end
end

if ~isfield(config, 'ppo_backcalculation')
    config.ppo_backcalculation = default.ppo_backcalculation;
end

if ~isfield(config, 'backcalculation')
    config.backcalculation = default.backcalculation;
end

end

function config = getDefaultConfig()
% 返回默认配置
config = struct();

config.ppo_backcalculation = struct();
config.ppo_backcalculation.max_episodes = 100;
config.ppo_backcalculation.max_steps_per_episode = 20;
config.ppo_backcalculation.early_stop_patience = 15;
config.ppo_backcalculation.learning_rate = 0.0003;

config.backcalculation = struct();
config.backcalculation.convergence_threshold = 0.05;

config.llm_guidance = struct();
config.llm_guidance.enabled = true;
config.llm_guidance.use_for_initial_estimate = true;
config.llm_guidance.use_for_optimization_guidance = true;
config.llm_guidance.guidance_interval = 5;

end