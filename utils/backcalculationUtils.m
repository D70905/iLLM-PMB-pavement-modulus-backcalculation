function varargout = backcalculationUtils(action, varargin)
% BACKCALCULATIONUTILS 反演系统工具函数集合
%
% 功能：提供结果保存、可视化和报告生成功能
%
% 用法：
%   backcalculationUtils('save', results, config)
%   backcalculationUtils('visualize', results)
%   backcalculationUtils('report', results, config)

switch lower(action)
    case 'save'
        saveBackcalculationResults(varargin{:});
        
    case 'visualize'
        visualizeBackcalculationResults(varargin{:});
        
    case 'report'
        generateBackcalculationReport(varargin{:});
        
    otherwise
        error('不支持的操作: %s', action);
end

end

%% ==================== 结果保存 ====================

function saveBackcalculationResults(results, config)
% SAVEBACKCALCULATIONRESULTS 保存反演结果
%
% 输入:
%   results - 反演结果结构体
%   config  - 配置参数

% 创建输出目录
output_dir = config.output.output_directory;
if ~exist(output_dir, 'dir')
    mkdir(output_dir);
    fprintf('  ✓ 创建输出目录: %s\n', output_dir);
end

% 生成时间戳
timestamp = datestr(now, 'yyyymmdd_HHMMSS');

% 保存为MAT文件
mat_filename = fullfile(output_dir, sprintf('backcalc_results_%s.mat', timestamp));
save(mat_filename, 'results');
fprintf('  ✓ 结果已保存为MAT格式: %s\n', mat_filename);

% 保存为JSON格式（便于查看和分析）
try
    json_filename = fullfile(output_dir, sprintf('backcalc_results_%s.json', timestamp));
    
    % 准备JSON数据（简化结构，避免复杂嵌套）
    json_data = struct();
    json_data.timestamp = datestr(results.timestamp);
    json_data.input_data = results.input_data;
    json_data.initial_modulus = results.initial_modulus;
    json_data.final_modulus = results.final_modulus;
    json_data.initial_error = results.initial_error;
    json_data.final_error = results.final_error;
    
    % 优化日志
    if isfield(results, 'optimization_log')
        json_data.optimization = struct();
        json_data.optimization.iterations = results.optimization_log.iterations;
        json_data.optimization.converged = results.optimization_log.converged;
        if isfield(results.optimization_log, 'total_time')
            json_data.optimization.total_time = results.optimization_log.total_time;
        end
        if isfield(results.optimization_log, 'final_deflection')
            json_data.optimization.final_deflection = results.optimization_log.final_deflection;
        end
    end
    
    % 敏感性分析结果
    if ~isempty(results.sensitivity) && isfield(results.sensitivity, 'quality_assessment')
        json_data.sensitivity = struct();
        json_data.sensitivity.quality_score = results.sensitivity.quality_assessment.overall_score;
        json_data.sensitivity.reliability = results.sensitivity.quality_assessment.reliability;
    end
    
    % 写入JSON文件
    json_str = jsonencode(json_data);
    fid = fopen(json_filename, 'w');
    fprintf(fid, '%s', json_str);
    fclose(fid);
    fprintf('  ✓ 结果已保存为JSON格式: %s\n', json_filename);
catch ME
    fprintf('  ⚠️ JSON保存失败: %s\n', ME.message);
end

% 保存为CSV格式（模量对比表）
try
    csv_filename = fullfile(output_dir, sprintf('backcalc_modulus_%s.csv', timestamp));
    fid = fopen(csv_filename, 'w');
    fprintf(fid, '结构层,初始模量(MPa),最终模量(MPa),变化(MPa),变化率(%%)\n');
    
    % 表面层
    change_surface = results.final_modulus.surface - results.initial_modulus.surface;
    change_rate_surface = change_surface / results.initial_modulus.surface * 100;
    fprintf(fid, '表面层,%d,%d,%d,%.2f\n', ...
        results.initial_modulus.surface, results.final_modulus.surface, ...
        change_surface, change_rate_surface);
    
    % 基层
    change_base = results.final_modulus.base - results.initial_modulus.base;
    change_rate_base = change_base / results.initial_modulus.base * 100;
    fprintf(fid, '基层,%d,%d,%d,%.2f\n', ...
        results.initial_modulus.base, results.final_modulus.base, ...
        change_base, change_rate_base);
    
    % 底基层
    change_subbase = results.final_modulus.subbase - results.initial_modulus.subbase;
    change_rate_subbase = change_subbase / results.initial_modulus.subbase * 100;
    fprintf(fid, '底基层,%d,%d,%d,%.2f\n', ...
        results.initial_modulus.subbase, results.final_modulus.subbase, ...
        change_subbase, change_rate_subbase);
    
    fclose(fid);
    fprintf('  ✓ 模量对比表已保存为CSV格式: %s\n', csv_filename);
catch ME
    fprintf('  ⚠️ CSV保存失败: %s\n', ME.message);
end

end

%% ==================== 结果可视化 ====================

function visualizeBackcalculationResults(results)
% VISUALIZEBACKCALCULATIONRESULTS 可视化反演结果
%
% 输入:
%   results - 反演结果结构体

try
    % 创建图形窗口
    fig = figure('Name', '路面结构模量反演结果', ...
                 'Position', [100, 100, 1200, 800], ...
                 'Color', 'w');
    
    % 子图1：模量对比
    subplot(2, 2, 1);
    layers = {'表面层', '基层', '底基层'};
    initial = [results.initial_modulus.surface; 
               results.initial_modulus.base; 
               results.initial_modulus.subbase];
    final = [results.final_modulus.surface; 
             results.final_modulus.base; 
             results.final_modulus.subbase];
    
    x = 1:3;
    b = bar(x, [initial, final]);
    b(1).FaceColor = [0.3, 0.6, 0.9];
    b(2).FaceColor = [0.9, 0.4, 0.3];
    set(gca, 'XTickLabel', layers, 'FontSize', 10);
    ylabel('模量 (MPa)', 'FontSize', 11);
    title('初始估计 vs 最终反演', 'FontSize', 12, 'FontWeight', 'bold');
    legend({'初始估计', '最终反演'}, 'Location', 'best');
    grid on;
    
    % 子图2：误差收敛历史
    subplot(2, 2, 2);
    if isfield(results.optimization_log, 'error_history') && ~isempty(results.optimization_log.error_history)
        error_history = results.optimization_log.error_history;
        if ~isempty(error_history)
            plot(error_history * 100, 'LineWidth', 2, 'Color', [0.2, 0.5, 0.7]);
            xlabel('Episode', 'FontSize', 11);
            ylabel('相对误差 (%)', 'FontSize', 11);
            title('误差收敛历史', 'FontSize', 12, 'FontWeight', 'bold');
            grid on;
            
            % 添加收敛阈值线
            if isfield(results.input_data, 'convergence_threshold')
                threshold = results.input_data.convergence_threshold * 100;
                hold on;
                plot([1, length(error_history)], [threshold, threshold], ...
                     '--r', 'LineWidth', 1.5);
                legend({'误差曲线', '收敛阈值'}, 'Location', 'best');
            end
        else
            text(0.5, 0.5, '无误差历史数据', 'HorizontalAlignment', 'center');
        end
    else
        text(0.5, 0.5, '无误差历史数据', 'HorizontalAlignment', 'center');
        axis off;
    end
    
    % 子图3：弯沉对比
    subplot(2, 2, 3);
    if isfield(results.optimization_log, 'final_deflection')
        deflections = [results.input_data.measured_deflection; 
                       results.optimization_log.final_deflection];
        bar_colors = [0.4, 0.7, 0.4; 0.7, 0.4, 0.4];
        b = bar([1, 2], deflections);
        b.FaceColor = 'flat';
        b.CData = bar_colors;
        set(gca, 'XTickLabel', {'实测弯沉', '计算弯沉'}, 'FontSize', 10);
        ylabel('弯沉 (mm)', 'FontSize', 11);
        title(sprintf('弯沉对比 (误差: %.2f%%)', results.final_error * 100), ...
              'FontSize', 12, 'FontWeight', 'bold');
        grid on;
        
        % 添加数值标签
        for i = 1:2
            text(i, deflections(i), sprintf('%.3f', deflections(i)), ...
                 'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
                 'FontSize', 9);
        end
    else
        text(0.5, 0.5, '无弯沉数据', 'HorizontalAlignment', 'center');
        axis off;
    end
    
    % 子图4：敏感性分析
    subplot(2, 2, 4);
    if ~isempty(results.sensitivity) && isfield(results.sensitivity, 'modulus_sensitivity')
        sens = results.sensitivity.modulus_sensitivity;
        sens_values = [sens.surface; sens.base; sens.subbase];
        b = bar(x, sens_values);
        b.FaceColor = [0.6, 0.3, 0.7];
        set(gca, 'XTickLabel', layers, 'FontSize', 10);
        ylabel('敏感性 (mm/MPa)', 'FontSize', 11);
        title('模量敏感性分析', 'FontSize', 12, 'FontWeight', 'bold');
        grid on;
        
        % 添加数值标签
        for i = 1:3
            text(i, sens_values(i), sprintf('%.4f', sens_values(i)), ...
                 'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
                 'FontSize', 8);
        end
    else
        % 如果没有敏感性数据，显示质量评估
        axis off;
        if ~isempty(results.sensitivity) && isfield(results.sensitivity, 'quality_assessment')
            text(0.5, 0.7, '反演质量评估', 'HorizontalAlignment', 'center', ...
                 'FontSize', 12, 'FontWeight', 'bold');
            text(0.5, 0.5, sprintf('得分: %.1f/100', results.sensitivity.quality_assessment.overall_score), ...
                 'HorizontalAlignment', 'center', 'FontSize', 11);
            text(0.5, 0.3, sprintf('等级: %s', results.sensitivity.quality_assessment.reliability), ...
                 'HorizontalAlignment', 'center', 'FontSize', 11);
        else
            text(0.5, 0.5, '无敏感性数据', 'HorizontalAlignment', 'center');
        end
    end
    
    % 总标题
    sgtitle('路面结构模量反演结果可视化', 'FontSize', 14, 'FontWeight', 'bold');
    
    % 保存图形
    if isfield(results, 'timestamp')
        timestamp = datestr(results.timestamp, 'yyyymmdd_HHMMSS');
        saveas(fig, sprintf('backcalc_results_%s.png', timestamp));
    end
    
catch ME
    fprintf('  ⚠️ 可视化失败: %s\n', ME.message);
end

end

%% ==================== 报告生成 ====================

function generateBackcalculationReport(results, config)
% GENERATEBACKCALCULATIONREPORT 生成文本分析报告
%
% 输入:
%   results - 反演结果结构体
%   config  - 配置参数

% 创建输出目录
output_dir = config.output.output_directory;
if ~exist(output_dir, 'dir')
    mkdir(output_dir);
end

% 生成报告文件名
timestamp = datestr(now, 'yyyymmdd_HHMMSS');
filename = fullfile(output_dir, sprintf('backcalc_report_%s.txt', timestamp));

try
    % 打开文件
    fid = fopen(filename, 'w', 'n', 'UTF-8');
    
    % 报告头部
    fprintf(fid, '╔════════════════════════════════════════════════════════════╗\n');
    fprintf(fid, '║        道路结构模量反演分析报告                            ║\n');
    fprintf(fid, '╚════════════════════════════════════════════════════════════╝\n\n');
    fprintf(fid, '生成时间: %s\n\n', datestr(results.timestamp));
    
    % 第一部分：输入数据
    fprintf(fid, '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
    fprintf(fid, '一、输入数据\n');
    fprintf(fid, '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n');
    
    fprintf(fid, '1.1 实测弯沉\n');
    fprintf(fid, '  • 实测弯沉值: %.3f mm\n\n', results.input_data.measured_deflection);
    
    fprintf(fid, '1.2 路面结构\n');
    for i = 1:length(results.input_data.layer_names)
        fprintf(fid, '  • %s: %.1f cm\n', ...
            results.input_data.layer_names{i}, results.input_data.thickness(i));
    end
    fprintf(fid, '\n');
    
    if isfield(results.input_data, 'test_temperature')
        fprintf(fid, '1.3 测试条件\n');
        fprintf(fid, '  • 测试温度: %.1f ℃\n', results.input_data.test_temperature);
        fprintf(fid, '  • 荷载压力: %.2f MPa\n', results.input_data.load_pressure);
        fprintf(fid, '  • 荷载半径: %.2f cm\n\n', results.input_data.load_radius);
    end
    
    % 第二部分：反演结果
    fprintf(fid, '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
    fprintf(fid, '二、反演结果\n');
    fprintf(fid, '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n');
    
    fprintf(fid, '2.1 模量反演结果\n');
    fprintf(fid, '  ┌─────────────┬──────────┬──────────┬──────────┐\n');
    fprintf(fid, '  │   结构层    │ 初始估计 │ 反演结果 │  变化率  │\n');
    fprintf(fid, '  ├─────────────┼──────────┼──────────┼──────────┤\n');
    
    % 表面层
    change_rate = (results.final_modulus.surface - results.initial_modulus.surface) / ...
                  results.initial_modulus.surface * 100;
    fprintf(fid, '  │ 表面层(MPa) │  %6d  │  %6d  │ %+6.1f%% │\n', ...
        results.initial_modulus.surface, results.final_modulus.surface, change_rate);
    
    % 基层
    change_rate = (results.final_modulus.base - results.initial_modulus.base) / ...
                  results.initial_modulus.base * 100;
    fprintf(fid, '  │ 基层(MPa)   │  %6d  │  %6d  │ %+6.1f%% │\n', ...
        results.initial_modulus.base, results.final_modulus.base, change_rate);
    
    % 底基层
    change_rate = (results.final_modulus.subbase - results.initial_modulus.subbase) / ...
                  results.initial_modulus.subbase * 100;
    fprintf(fid, '  │ 底基层(MPa) │  %6d  │  %6d  │ %+6.1f%% │\n', ...
        results.initial_modulus.subbase, results.final_modulus.subbase, change_rate);
    
    fprintf(fid, '  └─────────────┴──────────┴──────────┴──────────┘\n\n');
    
    fprintf(fid, '2.2 弯沉匹配情况\n');
    if isfield(results.optimization_log, 'final_deflection')
        fprintf(fid, '  • 实测弯沉:   %.3f mm\n', results.input_data.measured_deflection);
        fprintf(fid, '  • 计算弯沉:   %.3f mm\n', results.optimization_log.final_deflection);
        fprintf(fid, '  • 相对误差:   %.2f%%\n', results.final_error * 100);
        fprintf(fid, '  • 绝对误差:   %.4f mm\n\n', ...
            abs(results.optimization_log.final_deflection - results.input_data.measured_deflection));
    else
        fprintf(fid, '  • 最终误差:   %.2f%%\n\n', results.final_error * 100);
    end
    
    % 第三部分：优化统计
    fprintf(fid, '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
    fprintf(fid, '三、优化统计\n');
    fprintf(fid, '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n');
    
    fprintf(fid, '3.1 PPO优化过程\n');
    fprintf(fid, '  • 迭代次数:   %d\n', results.optimization_log.iterations);
    fprintf(fid, '  • 收敛状态:   %s\n', mat2str(results.optimization_log.converged));
    
    if isfield(results.optimization_log, 'total_time')
        fprintf(fid, '  • 优化耗时:   %.2f 秒\n', results.optimization_log.total_time);
    end
    
    if isfield(results.optimization_log, 'message')
        fprintf(fid, '  • 退出原因:   %s\n', results.optimization_log.message);
    end
    fprintf(fid, '\n');
    
    fprintf(fid, '3.2 初始估计评估\n');
    fprintf(fid, '  • 初始误差:   %.2f%%\n', results.initial_error * 100);
    fprintf(fid, '  • 误差改善:   %.2f%%\n\n', ...
        (results.initial_error - results.final_error) / results.initial_error * 100);
    
    % 第四部分：敏感性分析
    if ~isempty(results.sensitivity)
        fprintf(fid, '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
        fprintf(fid, '四、敏感性分析\n');
        fprintf(fid, '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n');
        
        if isfield(results.sensitivity, 'modulus_sensitivity')
            fprintf(fid, '4.1 模量敏感性\n');
            sens = results.sensitivity.modulus_sensitivity;
            fprintf(fid, '  • 表面层敏感性: %.6f mm/MPa\n', sens.surface);
            fprintf(fid, '  • 基层敏感性:   %.6f mm/MPa\n', sens.base);
            fprintf(fid, '  • 底基层敏感性: %.6f mm/MPa\n\n', sens.subbase);
        end
        
        if isfield(results.sensitivity, 'confidence_intervals')
            fprintf(fid, '4.2 置信区间 (置信度 %.0f%%)\n', ...
                results.sensitivity.confidence_intervals.confidence_level * 100);
            ci = results.sensitivity.confidence_intervals;
            fprintf(fid, '  • 表面层: [%.0f, %.0f] MPa\n', ci.surface);
            fprintf(fid, '  • 基层:   [%.0f, %.0f] MPa\n', ci.base);
            fprintf(fid, '  • 底基层: [%.0f, %.0f] MPa\n\n', ci.subbase);
        end
        
        if isfield(results.sensitivity, 'quality_assessment')
            fprintf(fid, '4.3 反演质量评估\n');
            fprintf(fid, '  • 综合得分:   %.1f/100\n', ...
                results.sensitivity.quality_assessment.overall_score);
            fprintf(fid, '  • 可靠性等级: %s\n\n', ...
                results.sensitivity.quality_assessment.reliability);
        end
    end
    
    % 报告尾部
    fprintf(fid, '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
    fprintf(fid, '报告结束\n');
    fprintf(fid, '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
    
    % 关闭文件
    fclose(fid);
    
    fprintf('  ✓ 分析报告已生成: %s\n', filename);
    
catch ME
    fprintf('  ⚠️ 报告生成失败: %s\n', ME.message);
    if exist('fid', 'var') && fid ~= -1
        fclose(fid);
    end
end

end