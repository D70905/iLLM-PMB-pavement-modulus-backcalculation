function analyzeABAQUSResults(results_file)
% ANALYZEABAQUSRESULTS - 分析ABAQUS反演结果并导出论文数据
%
% 功能：
%   1. 生成模量对比表（反演值 vs 真值）
%   2. 生成弯沉盆对比数据
%   3. 生成收敛曲线数据
%   4. 导出CSV/Excel供论文绘图使用
%   5. 自动生成LaTeX表格代码
%
% 使用方法：
%   analyzeABAQUSResults('test_results_ABAQUS_20251205_123456.mat')
%   analyzeABAQUSResults()  % 自动查找最新结果文件
%
% 作者：基于iLLM-PMB项目
% 日期：2025-12

fprintf('\n');
fprintf('╔════════════════════════════════════════════════════════════╗\n');
fprintf('║     ABAQUS反演结果分析器 - 论文数据导出工具               ║\n');
fprintf('╚════════════════════════════════════════════════════════════╝\n\n');

%% 1. 加载结果文件
if nargin < 1 || isempty(results_file)
    % 自动查找最新的结果文件
    files = dir('test_results_ABAQUS*.mat');
    if isempty(files)
        error('未找到ABAQUS测试结果文件！请先运行 runTestCases(''ABAQUS'')');
    end
    [~, idx] = max([files.datenum]);
    results_file = files(idx).name;
    fprintf('  自动加载最新结果: %s\n\n', results_file);
end

load(results_file, 'results');

%% 2. 提取所有案例数据
case_names = fieldnames(results);
n_cases = length(case_names);

fprintf('  找到 %d 个测试案例\n\n', n_cases);

%% 3. 创建输出目录
output_dir = 'paper_data';
if ~exist(output_dir, 'dir')
    mkdir(output_dir);
end
timestamp = datestr(now, 'yyyymmdd_HHMMSS');

%% ═══════════════════════════════════════════════════════════════════════
%  表1：模量反演结果对比表
%% ═══════════════════════════════════════════════════════════════════════
fprintf('【生成表1：模量反演结果对比表】\n');

% 初始化数据数组
modulus_table = cell(n_cases + 1, 14);
modulus_table(1, :) = {'Case', 'Structure', ...
    'AC_True', 'AC_Inv', 'AC_Err%', ...
    'BC_True', 'BC_Inv', 'BC_Err%', ...
    'SB_True', 'SB_Inv', 'SB_Err%', ...
    'SG_True', 'SG_Inv', 'SG_Err%'};

for i = 1:n_cases
    cname = case_names{i};
    r = results.(cname);
    
    if ~r.success
        continue;
    end
    
    % 获取结构类型
    if isfield(r.input_data, 'structure_type_cn')
        struct_type = r.input_data.structure_type_cn;
    else
        struct_type = '-';
    end
    
    modulus_table{i+1, 1} = cname;
    modulus_table{i+1, 2} = struct_type;
    
    % AC
    modulus_table{i+1, 3} = r.true_modulus.surface;
    modulus_table{i+1, 4} = r.final_modulus.surface;
    modulus_table{i+1, 5} = r.modulus_errors.surface;
    
    % BC
    modulus_table{i+1, 6} = r.true_modulus.base;
    modulus_table{i+1, 7} = r.final_modulus.base;
    modulus_table{i+1, 8} = r.modulus_errors.base;
    
    % SB
    modulus_table{i+1, 9} = r.true_modulus.subbase;
    modulus_table{i+1, 10} = r.final_modulus.subbase;
    modulus_table{i+1, 11} = r.modulus_errors.subbase;
    
    % SG
    modulus_table{i+1, 12} = r.true_modulus.subgrade;
    modulus_table{i+1, 13} = r.final_modulus.subgrade;
    modulus_table{i+1, 14} = r.modulus_errors.subgrade;
end

% 保存为CSV
modulus_csv = fullfile(output_dir, sprintf('Table1_Modulus_Comparison_%s.csv', timestamp));
writeCSV(modulus_csv, modulus_table);
fprintf('  ✓ 已保存: %s\n', modulus_csv);

%% ═══════════════════════════════════════════════════════════════════════
%  表2：弯沉盆对比表
%% ═══════════════════════════════════════════════════════════════════════
fprintf('\n【生成表2：弯沉盆拟合对比表】\n');

% 传感器位置
offsets = [0, 20, 30, 60, 90, 120, 150];
n_sensors = length(offsets);

% 初始化
basin_table = cell(n_cases + 1, 2 + 3*n_sensors);
header = {'Case', 'Structure'};
for j = 1:n_sensors
    header{end+1} = sprintf('D%d_Meas', offsets(j));
    header{end+1} = sprintf('D%d_Calc', offsets(j));
    header{end+1} = sprintf('D%d_Err%%', offsets(j));
end
basin_table(1, :) = header;

for i = 1:n_cases
    cname = case_names{i};
    r = results.(cname);
    
    if ~r.success
        continue;
    end
    
    % 获取结构类型
    if isfield(r.input_data, 'structure_type_cn')
        struct_type = r.input_data.structure_type_cn;
    else
        struct_type = '-';
    end
    
    basin_table{i+1, 1} = cname;
    basin_table{i+1, 2} = struct_type;
    
    % 实测弯沉盆
    measured = r.input_data.deflection_basin;
    
    % 计算弯沉盆
    if isfield(r.final_pde_results, 'deflections')
        calculated = r.final_pde_results.deflections;
    else
        calculated = zeros(1, n_sensors);
    end
    
    % 确保长度一致
    n = min([length(measured), length(calculated), n_sensors]);
    
    col = 3;
    for j = 1:n_sensors
        if j <= n
            basin_table{i+1, col} = measured(j);
            basin_table{i+1, col+1} = calculated(j);
            basin_table{i+1, col+2} = abs(measured(j) - calculated(j)) / measured(j) * 100;
        else
            basin_table{i+1, col} = NaN;
            basin_table{i+1, col+1} = NaN;
            basin_table{i+1, col+2} = NaN;
        end
        col = col + 3;
    end
end

% 保存为CSV
basin_csv = fullfile(output_dir, sprintf('Table2_Basin_Comparison_%s.csv', timestamp));
writeCSV(basin_csv, basin_table);
fprintf('  ✓ 已保存: %s\n', basin_csv);

%% ═══════════════════════════════════════════════════════════════════════
%  表3：误差统计汇总表
%% ═══════════════════════════════════════════════════════════════════════
fprintf('\n【生成表3：误差统计汇总表】\n');

% 收集所有误差
all_ac_err = [];
all_bc_err = [];
all_sb_err = [];
all_sg_err = [];
all_d0_err = [];
all_basin_err = [];
all_time = [];
all_episodes = [];

for i = 1:n_cases
    cname = case_names{i};
    r = results.(cname);
    
    if ~r.success
        continue;
    end
    
    all_ac_err(end+1) = r.modulus_errors.surface;
    all_bc_err(end+1) = r.modulus_errors.base;
    all_sb_err(end+1) = r.modulus_errors.subbase;
    all_sg_err(end+1) = r.modulus_errors.subgrade;
    all_d0_err(end+1) = r.final_error * 100;
    
    if isfield(r.optimization_log, 'best_error')
        all_basin_err(end+1) = r.optimization_log.best_error * 100;
    end
    if isfield(r.optimization_log, 'total_time')
        all_time(end+1) = r.optimization_log.total_time;
    end
    if isfield(r.optimization_log, 'iterations')
        all_episodes(end+1) = r.optimization_log.iterations;
    end
end

% 生成统计表
stats_table = cell(6, 6);
stats_table(1, :) = {'Metric', 'Mean', 'Std', 'Min', 'Max', 'Median'};
stats_table(2, :) = {'AC Error (%)', mean(all_ac_err), std(all_ac_err), min(all_ac_err), max(all_ac_err), median(all_ac_err)};
stats_table(3, :) = {'BC Error (%)', mean(all_bc_err), std(all_bc_err), min(all_bc_err), max(all_bc_err), median(all_bc_err)};
stats_table(4, :) = {'SB Error (%)', mean(all_sb_err), std(all_sb_err), min(all_sb_err), max(all_sb_err), median(all_sb_err)};
stats_table(5, :) = {'SG Error (%)', mean(all_sg_err), std(all_sg_err), min(all_sg_err), max(all_sg_err), median(all_sg_err)};
stats_table(6, :) = {'D0 Error (%)', mean(all_d0_err), std(all_d0_err), min(all_d0_err), max(all_d0_err), median(all_d0_err)};

% 保存
stats_csv = fullfile(output_dir, sprintf('Table3_Error_Statistics_%s.csv', timestamp));
writeCSV(stats_csv, stats_table);
fprintf('  ✓ 已保存: %s\n', stats_csv);

%% ═══════════════════════════════════════════════════════════════════════
%  表4：收敛性能表
%% ═══════════════════════════════════════════════════════════════════════
fprintf('\n【生成表4：收敛性能表】\n');

conv_table = cell(n_cases + 1, 7);
conv_table(1, :) = {'Case', 'Structure', 'Episodes', 'Time_s', 'LLM_Calls', 'Final_Error%', 'Converged'};

for i = 1:n_cases
    cname = case_names{i};
    r = results.(cname);
    
    if ~r.success
        continue;
    end
    
    if isfield(r.input_data, 'structure_type_cn')
        struct_type = r.input_data.structure_type_cn;
    else
        struct_type = '-';
    end
    
    conv_table{i+1, 1} = cname;
    conv_table{i+1, 2} = struct_type;
    conv_table{i+1, 3} = r.optimization_log.iterations;
    conv_table{i+1, 4} = r.optimization_log.total_time;
    conv_table{i+1, 5} = r.optimization_log.llm_call_count;
    conv_table{i+1, 6} = r.optimization_log.best_error * 100;
    conv_table{i+1, 7} = r.optimization_log.converged;
end

conv_csv = fullfile(output_dir, sprintf('Table4_Convergence_Performance_%s.csv', timestamp));
writeCSV(conv_csv, conv_table);
fprintf('  ✓ 已保存: %s\n', conv_csv);

%% ═══════════════════════════════════════════════════════════════════════
%  图1数据：收敛曲线
%% ═══════════════════════════════════════════════════════════════════════
fprintf('\n【生成图1数据：收敛曲线】\n');

% 选择代表性案例（每类结构选1个）
representative_cases = {'ABAQUS_1', 'ABAQUS_4', 'ABAQUS_7', 'ABAQUS_10', 'ABAQUS_13'};

for i = 1:length(representative_cases)
    cname = representative_cases{i};
    if ~isfield(results, cname)
        continue;
    end
    
    r = results.(cname);
    if ~r.success || ~isfield(r.optimization_log, 'error_history')
        continue;
    end
    
    err_history = r.optimization_log.error_history;
    n_ep = length(err_history);
    
    conv_data = [(1:n_ep)', err_history(:) * 100];
    
    conv_file = fullfile(output_dir, sprintf('Fig1_Convergence_%s_%s.csv', cname, timestamp));
    
    fid = fopen(conv_file, 'w');
    fprintf(fid, 'Episode,Error_Percent\n');
    for j = 1:n_ep
        fprintf(fid, '%d,%.4f\n', j, conv_data(j, 2));
    end
    fclose(fid);
    
    fprintf('  ✓ %s: %s\n', cname, conv_file);
end

%% ═══════════════════════════════════════════════════════════════════════
%  图2数据：弯沉盆形状对比（选择典型案例）
%% ═══════════════════════════════════════════════════════════════════════
fprintf('\n【生成图2数据：弯沉盆形状对比】\n');

for i = 1:length(representative_cases)
    cname = representative_cases{i};
    if ~isfield(results, cname)
        continue;
    end
    
    r = results.(cname);
    if ~r.success
        continue;
    end
    
    measured = r.input_data.deflection_basin;
    if isfield(r.final_pde_results, 'deflections')
        calculated = r.final_pde_results.deflections;
    else
        continue;
    end
    
    n = min(length(measured), length(calculated));
    
    basin_file = fullfile(output_dir, sprintf('Fig2_Basin_%s_%s.csv', cname, timestamp));
    
    fid = fopen(basin_file, 'w');
    fprintf(fid, 'Offset_cm,Measured_mm,Calculated_mm\n');
    for j = 1:n
        fprintf(fid, '%d,%.4f,%.4f\n', offsets(j), measured(j), calculated(j));
    end
    fclose(fid);
    
    fprintf('  ✓ %s: %s\n', cname, basin_file);
end

%% ═══════════════════════════════════════════════════════════════════════
%  生成LaTeX表格代码
%% ═══════════════════════════════════════════════════════════════════════
fprintf('\n【生成LaTeX表格代码】\n');

latex_file = fullfile(output_dir, sprintf('LaTeX_Tables_%s.tex', timestamp));
fid = fopen(latex_file, 'w');

% 表1：模量对比
fprintf(fid, '%%%% Table 1: Modulus Comparison\n');
fprintf(fid, '\\begin{table}[htbp]\n');
fprintf(fid, '\\centering\n');
fprintf(fid, '\\caption{Backcalculated moduli compared with true values}\n');
fprintf(fid, '\\label{tab:modulus_comparison}\n');
fprintf(fid, '\\begin{tabular}{lcccccccccccc}\n');
fprintf(fid, '\\hline\n');
fprintf(fid, 'Case & \\multicolumn{3}{c}{AC (MPa)} & \\multicolumn{3}{c}{BC (MPa)} & \\multicolumn{3}{c}{SB (MPa)} & \\multicolumn{3}{c}{SG (MPa)} \\\\\n');
fprintf(fid, '     & True & Inv. & Err. & True & Inv. & Err. & True & Inv. & Err. & True & Inv. & Err. \\\\\n');
fprintf(fid, '\\hline\n');

for i = 1:n_cases
    cname = case_names{i};
    r = results.(cname);
    if ~r.success, continue; end
    
    % 简化案例名
    case_short = strrep(cname, 'ABAQUS_', '');
    
    fprintf(fid, '%s & %d & %d & %.1f & %d & %d & %.1f & %d & %d & %.1f & %d & %d & %.1f \\\\\n', ...
        case_short, ...
        r.true_modulus.surface, r.final_modulus.surface, r.modulus_errors.surface, ...
        r.true_modulus.base, r.final_modulus.base, r.modulus_errors.base, ...
        r.true_modulus.subbase, r.final_modulus.subbase, r.modulus_errors.subbase, ...
        r.true_modulus.subgrade, round(r.final_modulus.subgrade), r.modulus_errors.subgrade);
end

fprintf(fid, '\\hline\n');
fprintf(fid, 'Mean & - & - & %.1f & - & - & %.1f & - & - & %.1f & - & - & %.1f \\\\\n', ...
    mean(all_ac_err), mean(all_bc_err), mean(all_sb_err), mean(all_sg_err));
fprintf(fid, '\\hline\n');
fprintf(fid, '\\end{tabular}\n');
fprintf(fid, '\\end{table}\n\n');

% 表2：统计汇总
fprintf(fid, '%%%% Table 2: Error Statistics Summary\n');
fprintf(fid, '\\begin{table}[htbp]\n');
fprintf(fid, '\\centering\n');
fprintf(fid, '\\caption{Statistical summary of backcalculation errors}\n');
fprintf(fid, '\\label{tab:error_statistics}\n');
fprintf(fid, '\\begin{tabular}{lccccc}\n');
fprintf(fid, '\\hline\n');
fprintf(fid, 'Layer & Mean (\\%%) & Std (\\%%) & Min (\\%%) & Max (\\%%) & Median (\\%%) \\\\\n');
fprintf(fid, '\\hline\n');
fprintf(fid, 'Surface (AC) & %.2f & %.2f & %.2f & %.2f & %.2f \\\\\n', mean(all_ac_err), std(all_ac_err), min(all_ac_err), max(all_ac_err), median(all_ac_err));
fprintf(fid, 'Base (BC) & %.2f & %.2f & %.2f & %.2f & %.2f \\\\\n', mean(all_bc_err), std(all_bc_err), min(all_bc_err), max(all_bc_err), median(all_bc_err));
fprintf(fid, 'Subbase (SB) & %.2f & %.2f & %.2f & %.2f & %.2f \\\\\n', mean(all_sb_err), std(all_sb_err), min(all_sb_err), max(all_sb_err), median(all_sb_err));
fprintf(fid, 'Subgrade (SG) & %.2f & %.2f & %.2f & %.2f & %.2f \\\\\n', mean(all_sg_err), std(all_sg_err), min(all_sg_err), max(all_sg_err), median(all_sg_err));
fprintf(fid, '\\hline\n');
fprintf(fid, '\\end{tabular}\n');
fprintf(fid, '\\end{table}\n');

fclose(fid);
fprintf('  ✓ 已保存: %s\n', latex_file);

%% ═══════════════════════════════════════════════════════════════════════
%  打印控制台汇总
%% ═══════════════════════════════════════════════════════════════════════
fprintf('\n');
fprintf('╔════════════════════════════════════════════════════════════════════════════╗\n');
fprintf('║                         反演结果统计汇总                                  ║\n');
fprintf('╚════════════════════════════════════════════════════════════════════════════╝\n\n');

fprintf('【模量反演误差统计】\n');
fprintf('  ┌──────────┬─────────┬─────────┬─────────┬─────────┬─────────┐\n');
fprintf('  │ 层位     │ 平均    │ 标准差  │ 最小    │ 最大    │ 中位数  │\n');
fprintf('  ├──────────┼─────────┼─────────┼─────────┼─────────┼─────────┤\n');
fprintf('  │ 面层 AC  │ %6.2f%% │ %6.2f%% │ %6.2f%% │ %6.2f%% │ %6.2f%% │\n', mean(all_ac_err), std(all_ac_err), min(all_ac_err), max(all_ac_err), median(all_ac_err));
fprintf('  │ 基层 BC  │ %6.2f%% │ %6.2f%% │ %6.2f%% │ %6.2f%% │ %6.2f%% │\n', mean(all_bc_err), std(all_bc_err), min(all_bc_err), max(all_bc_err), median(all_bc_err));
fprintf('  │ 底基 SB  │ %6.2f%% │ %6.2f%% │ %6.2f%% │ %6.2f%% │ %6.2f%% │\n', mean(all_sb_err), std(all_sb_err), min(all_sb_err), max(all_sb_err), median(all_sb_err));
fprintf('  │ 土基 SG  │ %6.2f%% │ %6.2f%% │ %6.2f%% │ %6.2f%% │ %6.2f%% │\n', mean(all_sg_err), std(all_sg_err), min(all_sg_err), max(all_sg_err), median(all_sg_err));
fprintf('  └──────────┴─────────┴─────────┴─────────┴─────────┴─────────┘\n');

fprintf('\n【收敛性能统计】\n');
fprintf('  平均迭代次数: %.1f episodes\n', mean(all_episodes));
fprintf('  平均运行时间: %.1f 秒\n', mean(all_time));
fprintf('  收敛成功率:   %.1f%%\n', sum([results.(case_names{1}).optimization_log.converged]) / n_cases * 100);

fprintf('\n【输出文件列表】\n');
fprintf('  目录: %s/\n', output_dir);
fprintf('  - Table1_Modulus_Comparison_*.csv    (模量对比表)\n');
fprintf('  - Table2_Basin_Comparison_*.csv      (弯沉盆对比表)\n');
fprintf('  - Table3_Error_Statistics_*.csv      (误差统计表)\n');
fprintf('  - Table4_Convergence_Performance_*.csv (收敛性能表)\n');
fprintf('  - Fig1_Convergence_*.csv             (收敛曲线数据)\n');
fprintf('  - Fig2_Basin_*.csv                   (弯沉盆绘图数据)\n');
fprintf('  - LaTeX_Tables_*.tex                 (LaTeX表格代码)\n');

fprintf('\n✅ 分析完成！所有论文数据已导出到 %s/ 目录\n\n', output_dir);

end

%% ═══════════════════════════════════════════════════════════════════════
%  辅助函数：写入CSV
%% ═══════════════════════════════════════════════════════════════════════
function writeCSV(filename, data)
    fid = fopen(filename, 'w');
    [nrows, ncols] = size(data);
    
    for i = 1:nrows
        for j = 1:ncols
            val = data{i, j};
            if ischar(val)
                fprintf(fid, '%s', val);
            elseif islogical(val)
                fprintf(fid, '%d', val);
            elseif isnumeric(val)
                if isnan(val)
                    fprintf(fid, '');
                elseif val == round(val)
                    fprintf(fid, '%d', val);
                else
                    fprintf(fid, '%.4f', val);
                end
            end
            
            if j < ncols
                fprintf(fid, ',');
            end
        end
        fprintf(fid, '\n');
    end
    
    fclose(fid);
end
