%% resumeAndFinishAnalysis.m - 从临时文件恢复并完成统计分析
%
% 用途：
%   当 runAblationStudy_v2_3.m 在统计分析阶段（步骤7）报错后，
%   使用此脚本从临时文件加载已完成的运行结果，并使用修复后的
%   统计函数完成分析和输出文件生成。
%
% 使用方法：
%   1. 找到临时文件名（格式：AblationResults_Temp_yyyymmdd_HHMMSS.mat）
%   2. 修改下方的 temp_file 变量为您的临时文件名
%   3. 运行此脚本
%
% 日期：2025-12-17

%% ═══════════════════════════════════════════════════════════════════════
%  配置：请修改为您的临时文件名
%% ═══════════════════════════════════════════════════════════════════════

% 【重要】请将下面的文件名替换为您的实际临时文件名
% 可以使用 dir('AblationResults_Temp_*.mat') 来查找
temp_file = 'AblationResults_Temp_*.mat';  % 使用通配符自动查找最新的

%% ═══════════════════════════════════════════════════════════════════════
%  自动查找临时文件
%% ═══════════════════════════════════════════════════════════════════════

fprintf('\n');
fprintf('╔════════════════════════════════════════════════════════════╗\n');
fprintf('║   临时文件恢复与统计分析脚本                              ║\n');
fprintf('╚════════════════════════════════════════════════════════════╝\n\n');

if contains(temp_file, '*')
    % 自动查找临时文件
    files = dir('AblationResults_Temp_*.mat');
    if isempty(files)
        error('未找到临时文件！请确保在正确的目录中运行。');
    end
    
    % 选择最新的文件
    [~, idx] = max([files.datenum]);
    temp_file = files(idx).name;
    fprintf('  自动找到临时文件: %s\n', temp_file);
else
    if ~exist(temp_file, 'file')
        error('指定的临时文件不存在: %s', temp_file);
    end
end

%% ═══════════════════════════════════════════════════════════════════════
%  加载临时文件
%% ═══════════════════════════════════════════════════════════════════════

fprintf('\n【步骤1】加载临时文件...\n');
load(temp_file, 'results');

fprintf('  ✓ 临时文件加载成功\n');
fprintf('    时间戳: %s\n', results.metadata.timestamp);
fprintf('    总运行次数: %d\n', length(results.runs));
fprintf('    成功: %d, 失败: %d\n', ...
    sum([results.runs.success]), sum(~[results.runs.success]));

%% ═══════════════════════════════════════════════════════════════════════
%  重新定义变体（用于统计分析）
%% ═══════════════════════════════════════════════════════════════════════

fprintf('\n【步骤2】重新定义变体...\n');

variants = struct();

% 变体1: Full
variants(1).name = 'Full';
variants(1).display_name = 'LLM-PPO (Full)';

% 变体2: w/o LLM-Guide
variants(2).name = 'w/o_Guide';
variants(2).display_name = 'w/o LLM-Guide';

% 变体3: w/o LLM-Init
variants(3).name = 'w/o_Init';
variants(3).display_name = 'w/o LLM-Init';

% 变体4: Pure PPO
variants(4).name = 'Pure_PPO';
variants(4).display_name = 'Pure PPO';

selected_cases = results.metadata.selected_cases;
fprintf('  ✓ 变体定义完成\n');

%% ═══════════════════════════════════════════════════════════════════════
%  重新运行统计分析（使用修复后的函数）
%% ═══════════════════════════════════════════════════════════════════════

fprintf('\n【步骤3】运行统计分析（使用修复后的字段名处理）...\n');

results.metadata.end_time = now;
if ~isfield(results.metadata, 'total_elapsed_time') || isempty(results.metadata.total_elapsed_time)
    results.metadata.total_elapsed_time = 0;  % 无法准确计算总时间
end

results.statistics = computeStatisticsFixed(results.runs, variants, selected_cases);

fprintf('  ✓ 统计分析完成\n');
fprintf('    成功率: %.1f%% (%d/%d)\n', ...
    results.statistics.success_rate*100, ...
    results.statistics.successful_runs, ...
    results.statistics.total_runs);

%% ═══════════════════════════════════════════════════════════════════════
%  生成输出文件
%% ═══════════════════════════════════════════════════════════════════════

fprintf('\n【步骤4】生成输出文件...\n');

timestamp = results.metadata.timestamp;

% 保存完整结果
mat_filename = sprintf('AblationResults_%s.mat', timestamp);
save(mat_filename, 'results');
fprintf('  ✓ 完整结果已保存: %s\n', mat_filename);

% 生成CSV表格
csv_filename = sprintf('AblationTable_%s.csv', timestamp);
generateAblationTableCSVFixed(results, csv_filename, variants);
fprintf('  ✓ 论文表格已生成: %s\n', csv_filename);

% 生成统计汇总
summary_filename = sprintf('AblationSummary_%s.txt', timestamp);
generateSummaryTextFixed(results, summary_filename, variants);
fprintf('  ✓ 统计汇总已生成: %s\n', summary_filename);

%% ═══════════════════════════════════════════════════════════════════════
%  打印最终摘要
%% ═══════════════════════════════════════════════════════════════════════

fprintf('\n');
fprintf('╔════════════════════════════════════════════════════════════╗\n');
fprintf('║   分析完成！                                              ║\n');
fprintf('╠════════════════════════════════════════════════════════════╣\n');
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
        if strcmp(makeValidFieldNameLocal(variants(v).name), vname)
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

%% ═══════════════════════════════════════════════════════════════════════
%  本地辅助函数
%% ═══════════════════════════════════════════════════════════════════════

function valid_name = makeValidFieldNameLocal(name)
% 将字符串转换为有效的MATLAB结构体字段名
valid_name = strrep(name, '/', '_');
valid_name = strrep(valid_name, ' ', '_');
valid_name = strrep(valid_name, '-', '_');
valid_name = strrep(valid_name, '.', '_');
end

function stats = computeStatisticsFixed(runs, variants, selected_cases)
% 计算统计汇总（修复版 - 处理变体名称中的非法字符）

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
        % 【关键修复】使用 makeValidFieldNameLocal 转换字段名
        valid_field_name = makeValidFieldNameLocal(variant_name);
        
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

function generateAblationTableCSVFixed(results, filename, variants)
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

function generateSummaryTextFixed(results, filename, variants)
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
    % 使用修复后的字段名
    vname = makeValidFieldNameLocal(variants(v).name);
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