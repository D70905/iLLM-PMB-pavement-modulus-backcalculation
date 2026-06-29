function runMultiLoadValidation()
% RUNMULTILOADVALIDATION  足尺环道多荷载验证实验
%
% 【功能】
%   方案A：荷载归一化验证（线弹性假设检验）
%     - 用50kN反算模量E*，预测68/88/109kN弯沉，与实测对比
%   方案B：扩充验证数据集
%     - 将各荷载等级归一化为等效50kN，各自独立反算，统计一致性
%
% 【用法】
%   cd 到项目根目录后运行: runMultiLoadValidation()
%
% 【输出】
%   output/multiload_validation/ 目录下的CSV结果和图表

fprintf('╔══════════════════════════════════════════════════════════════╗\n');
fprintf('║       多荷载验证实验 (方案A + 方案B)                        ║\n');
fprintf('╚══════════════════════════════════════════════════════════════╝\n\n');

%% ===== 路径配置 =====
project_root = fileparts(fileparts(mfilename('fullpath')));  % tests/的上级
addpath(fullfile(project_root, 'backcalculation'));
addpath(fullfile(project_root, 'core'));
addpath(fullfile(project_root, 'utils'));

output_dir = fullfile(project_root, 'output', 'multiload_validation');
if ~exist(output_dir, 'dir'), mkdir(output_dir); end

%% ===== 加载配置和数据 =====
config_file = fullfile(project_root, 'config_backcalculation.json');
if exist(config_file, 'file')
    config_text = fileread(config_file);
    config = jsondecode(config_text);
else
    config = getDefaultValidationConfig();
end

data_file = fullfile(project_root, 'data', 'multi_load_validation_data.csv');
if ~exist(data_file, 'file')
    error('数据文件不存在: %s\n请先按说明创建 multi_load_validation_data.csv', data_file);
end

raw_data = readtable(data_file, 'TextType', 'string');
raw_data = raw_data(strcmp(raw_data.section_id, "STR1"), :);
fprintf('✅ 加载数据: %d 行记录\n', height(raw_data));

%% ===== 数据分组 =====
% 找出所有50kN基准记录
mask_50kN = raw_data.load_kN == 50;
base_data  = raw_data(mask_50kN, :);
other_data = raw_data(~mask_50kN, :);

fprintf('   50kN基准记录: %d 条\n', height(base_data));
fprintf('   其他荷载记录: %d 条\n\n', height(other_data));

%% ===================================================================
%% ===== 方案A：先对所有50kN记录完成反算，得到E* =====
%% ===================================================================
fprintf('══════════════════════════════════════════════════════════════\n');
fprintf('  方案A Step 1/2：对所有50kN记录执行反算，获取E*\n');
fprintf('══════════════════════════════════════════════════════════════\n\n');

backcalc_results_50kN = runBackcalcBatch(base_data, config, '50kN_backcalc');

% 保存50kN反算结果
save_50kN_file = fullfile(output_dir, 'backcalc_50kN_results.csv');
saveBackcalcResults(backcalc_results_50kN, save_50kN_file);
fprintf('✅ 50kN反算结果已保存: %s\n\n', save_50kN_file);

%% ===== 方案A Step 2：用E*预测其他荷载弯沉，验证线弹性假设 =====
fprintf('══════════════════════════════════════════════════════════════\n');
fprintf('  方案A Step 2/2：用E*正向预测 68/88/109kN 弯沉\n');
fprintf('══════════════════════════════════════════════════════════════\n\n');

scheme_A_results = runLinearElasticValidation(backcalc_results_50kN, other_data, base_data);

save_A_file = fullfile(output_dir, 'schemeA_linear_elastic_validation.csv');
saveSchemeAResults(scheme_A_results, save_A_file);
fprintf('✅ 方案A结果已保存: %s\n\n', save_A_file);

%% ===================================================================
%% ===== 方案B：将各荷载归一化为等效50kN，各自独立反算 =====
%% ===================================================================
fprintf('══════════════════════════════════════════════════════════════\n');
fprintf('  方案B：多荷载归一化独立反算\n');
fprintf('══════════════════════════════════════════════════════════════\n\n');

normalized_data = normalizeToReference(raw_data, 50);
fprintf('  归一化后共 %d 条独立验证记录\n\n', height(normalized_data));

backcalc_results_all = runBackcalcBatch(normalized_data, config, 'normalized_all');

save_B_file = fullfile(output_dir, 'schemeB_all_backcalc_results.csv');
saveBackcalcResults(backcalc_results_all, save_B_file);
fprintf('✅ 方案B反算结果已保存: %s\n\n', save_B_file);

%% ===== 方案B：一致性分析 =====
scheme_B_consistency = analyzeConsistency(backcalc_results_all, raw_data);
save_B_cons_file = fullfile(output_dir, 'schemeB_consistency_analysis.csv');
saveConsistencyResults(scheme_B_consistency, save_B_cons_file);
fprintf('✅ 方案B一致性分析已保存: %s\n\n', save_B_cons_file);

%% ===== 绘图 =====
fprintf('══════════════════════════════════════════════════════════════\n');
fprintf('  生成论文图表\n');
fprintf('══════════════════════════════════════════════════════════════\n\n');

plotSchemeAResults(scheme_A_results, output_dir);
plotSchemeBResults(scheme_B_consistency, output_dir);

%% ===== 打印汇总 =====
printSummary(scheme_A_results, scheme_B_consistency);

fprintf('\n✅ 多荷载验证实验完成！所有结果保存在:\n   %s\n\n', output_dir);
end


%% ====================================================================
%% ==================== 核心子函数 ====================================
%% ====================================================================

function results = runBackcalcBatch(data_table, config, batch_name)
% 批量运行反算，对data_table中每行独立执行iLLM-PMB系统

n = height(data_table);
fprintf('  [%s] 开始批量反算，共 %d 条记录...\n', batch_name, n);

% 预分配结果结构体数组
results = struct();
results(n).section_id = '';  % 预分配

for i = 1:n
    row = data_table(i, :);
    fprintf('\n  ── [%d/%d] %s %s (%.0fkN) ──\n', ...
        i, n, row.section_id{1}, row.station{1}, row.load_kN);
    
    try
        % 构建input_data（与runBackcalculation.m中格式完全一致）
        input_data = buildInputData(row);
        
        % 生成初始模量（使用经验法，不调用LLM，加快批量速度）
        initial_modulus = initialModulusGenerator(input_data, config, 'empirical');
        
        % 初始PDE
        initial_params  = constructPDEParams_local(input_data, initial_modulus);
        initial_pde     = performPDE_local(initial_params, input_data);
        
        % 检查初始误差
        init_D0    = getD0_local(initial_pde);
        init_error = abs(init_D0 - input_data.measured_deflection) / ...
                     input_data.measured_deflection;
        
        if init_error < config.backcalculation.convergence_threshold
            % 初始估计已满足精度
            final_modulus = initial_modulus;
            final_pde     = initial_pde;
            opt_log       = struct('converged', true, 'iterations', 0, ...
                                   'best_error', init_error, 'total_time', 0);
        else
            % 运行PPO反算
            agent = BackcalculationPPO(input_data, config, initial_modulus, initial_pde);
            [final_modulus, opt_log] = agent.optimize();
            final_params = constructPDEParams_local(input_data, final_modulus);
            final_pde    = performPDE_local(final_params, input_data);
        end
        
        % 计算最终误差
        final_D0 = getD0_local(final_pde);
        final_error = abs(final_D0 - input_data.measured_deflection) / ...
                      input_data.measured_deflection;
        
        % 弯沉盆误差
        n_s = length(input_data.deflection_basin);
        if isfield(final_pde, 'deflections') && length(final_pde.deflections) >= n_s
            basin_err = abs(final_pde.deflections(1:n_s) - input_data.deflection_basin) ./ ...
                        input_data.deflection_basin * 100;
            basin_rmse = sqrt(mean((final_pde.deflections(1:n_s) - ...
                                    input_data.deflection_basin).^2));
        else
            basin_err  = nan(1, n_s);
            basin_rmse = nan;
        end
        
        % 记录结果
        results(i).section_id    = row.section_id{1};
        results(i).station       = row.station{1};
        results(i).load_kN       = row.load_kN;
        results(i).AC_MPa        = round(final_modulus.surface);
        results(i).BC_MPa        = round(final_modulus.base);
        results(i).SB_MPa        = round(final_modulus.subbase);
        results(i).SG_MPa        = round(final_modulus.subgrade);
        results(i).D0_error_pct  = final_error * 100;
        results(i).basin_rmse_mm = basin_rmse;
        results(i).basin_errors  = basin_err;
        results(i).converged     = opt_log.converged;
        results(i).iterations    = opt_log.iterations;
        results(i).final_pde     = final_pde;
        results(i).input_data    = input_data;
        results(i).final_modulus = final_modulus;
        
        fprintf('  ✅ 完成: AC=%d BC=%d SB=%d SG=%d MPa | D0误差=%.2f%%\n', ...
            results(i).AC_MPa, results(i).BC_MPa, results(i).SB_MPa, ...
            results(i).SG_MPa, results(i).D0_error_pct);
        
    catch ME
        fprintf('  ⚠️ 失败: %s\n', ME.message);
        results(i).section_id   = row.section_id{1};
        results(i).station      = row.station{1};
        results(i).load_kN      = row.load_kN;
        results(i).AC_MPa       = nan;
        results(i).BC_MPa       = nan;
        results(i).SB_MPa       = nan;
        results(i).SG_MPa       = nan;
        results(i).D0_error_pct = nan;
        results(i).converged    = false;
        results(i).iterations   = 0;
    end
end

n_ok = sum([results.converged]);
fprintf('\n  [%s] 批量完成: %d/%d 收敛 (%.1f%%)\n', batch_name, n_ok, n, n_ok/n*100);
end


function scheme_A_results = runLinearElasticValidation(backcalc_50kN, other_data, base_data)
% 方案A核心：用50kN的E*，正向预测其他荷载下弯沉，与实测对比

n_base   = length(backcalc_50kN);
n_other  = height(other_data);
results  = struct();
idx      = 0;

for i = 1:n_base
    if ~backcalc_50kN(i).converged, continue; end
    
    sec = backcalc_50kN(i).section_id;
    sta = backcalc_50kN(i).station;
    E_star = backcalc_50kN(i).final_modulus;
    input_ref = backcalc_50kN(i).input_data;
    
    % 找该桩号的其他荷载数据
    match = strcmp(other_data.section_id, sec) & strcmp(other_data.station, sta);
    other_rows = other_data(match, :);
    
    for j = 1:height(other_rows)
        row = other_rows(j, :);
        idx = idx + 1;
        
        % 用E*和新荷载参数做正向PDE计算
        input_fwd = input_ref;
        input_fwd.load_pressure = row.load_pressure_MPa;
        input_fwd.load_kN       = row.load_kN;
        
        try
            params_fwd  = constructPDEParams_local(input_fwd, E_star);
            pde_fwd     = performPDE_local(params_fwd, input_fwd);
            pred_basin  = pde_fwd.deflections;
            
            % 实测弯沉
            meas_basin = [row.D0_mm, row.D23_mm, row.D53_mm, row.D69_mm, ...
                          row.D85_mm, row.D116_mm, row.D153_mm];
            
            n_s = min(length(pred_basin), 7);
            pred_basin = pred_basin(1:n_s);
            meas_basin = meas_basin(1:n_s);
            
            % 计算误差指标
            D0_error_pct = abs(pred_basin(1) - meas_basin(1)) / meas_basin(1) * 100;
            rmse = sqrt(mean((pred_basin - meas_basin).^2));
            
            % 线性缩放对比（纯线性预测）
            scale_factor  = row.load_kN / 50;
            linear_pred   = backcalc_50kN(i).final_pde.deflections(1:n_s) * scale_factor;
            rmse_linear   = sqrt(mean((linear_pred - meas_basin).^2));
            LDC = rmse / max(rmse_linear, 1e-6);  % 线性偏差系数
            
            results(idx).section_id   = sec;
            results(idx).station      = sta;
            results(idx).load_kN      = row.load_kN;
            results(idx).D0_error_pct = D0_error_pct;
            results(idx).rmse_mm      = rmse;
            results(idx).LDC          = LDC;
            results(idx).pred_basin   = pred_basin;
            results(idx).meas_basin   = meas_basin;
            results(idx).AC_MPa       = round(E_star.surface);
            results(idx).BC_MPa       = round(E_star.base);
            results(idx).linear_elastic_valid = (LDC < 1.1 && D0_error_pct < 10);
            
        catch ME
            results(idx).section_id   = sec;
            results(idx).station      = sta;
            results(idx).load_kN      = row.load_kN;
            results(idx).D0_error_pct = nan;
            results(idx).rmse_mm      = nan;
            results(idx).LDC          = nan;
            results(idx).pred_basin   = nan(1,7);
            results(idx).meas_basin   = nan(1,7);
            results(idx).AC_MPa       = round(E_star.surface);
            results(idx).BC_MPa       = round(E_star.base);
            results(idx).linear_elastic_valid = false;
        end
    end
end

scheme_A_results = results;
fprintf('  方案A完成: %d 组跨荷载预测\n', idx);
end


function normalized_table = normalizeToReference(raw_data, ref_kN)
% 方案B：将各荷载等级弯沉归一化为等效ref_kN（默认50kN）弯沉

n = height(raw_data);
normalized_table = raw_data;  % 复制结构

deflection_cols = {'D0_mm','D23_mm','D53_mm','D69_mm','D85_mm','D116_mm','D153_mm'};

for i = 1:n
    F = raw_data.load_kN(i);
    if F == ref_kN, continue; end  % 基准荷载不需要归一化
    
    k = ref_kN / F;  % 归一化系数
    
    for c = 1:length(deflection_cols)
        col = deflection_cols{c};
        if ismember(col, normalized_table.Properties.VariableNames)
            normalized_table.(col)(i) = raw_data.(col)(i) * k;
        end
    end
    
    % 荷载参数也统一替换为参考荷载
    normalized_table.load_kN(i) = ref_kN;
    normalized_table.load_pressure_MPa(i) = ref_kN * 1000 / (pi * (15/100)^2 * 1e6);
end

% 添加原始荷载记录列（用于后续一致性分析）
normalized_table.original_load_kN = raw_data.load_kN;
end


function consistency = analyzeConsistency(all_results, raw_data)
% 方案B一致性分析：同桩号不同荷载等级反算结果的变异系数

sections = unique({all_results.section_id});
idx = 0;
consistency = struct();

for s = 1:length(sections)
    sec = sections{s};
    stations_in_sec = unique({all_results([all_results.section_id] == string(sec)).station});
    
    for st = 1:length(stations_in_sec)
        sta = stations_in_sec{st};
        
        % 找该桩号所有荷载等级的反算结果
        mask = strcmp({all_results.section_id}, sec) & strcmp({all_results.station}, sta);
        group = all_results(mask);
        
        if length(group) < 2, continue; end
        
        % 过滤掉未收敛的
        valid = group([group.converged]);
        if length(valid) < 2, continue; end
        
        AC_vals = [valid.AC_MPa];
        BC_vals = [valid.BC_MPa];
        SB_vals = [valid.SB_MPa];
        
        idx = idx + 1;
        consistency(idx).section_id = sec;
        consistency(idx).station    = sta;
        consistency(idx).n_valid    = length(valid);
        consistency(idx).load_levels = [valid.load_kN];
        
        consistency(idx).AC_mean = mean(AC_vals);
        consistency(idx).AC_std  = std(AC_vals);
        consistency(idx).AC_CV   = std(AC_vals) / mean(AC_vals) * 100;
        
        consistency(idx).BC_mean = mean(BC_vals);
        consistency(idx).BC_std  = std(BC_vals);
        consistency(idx).BC_CV   = std(BC_vals) / mean(BC_vals) * 100;
        
        consistency(idx).SB_mean = mean(SB_vals);
        consistency(idx).SB_std  = std(SB_vals);
        consistency(idx).SB_CV   = std(SB_vals) / mean(SB_vals) * 100;
        
        % 整体可信度评级
        max_CV = max([consistency(idx).AC_CV, consistency(idx).BC_CV, consistency(idx).SB_CV]);
        if max_CV < 15
            consistency(idx).reliability = 'High';
        elseif max_CV < 30
            consistency(idx).reliability = 'Medium';
        else
            consistency(idx).reliability = 'Low';
        end
    end
end

fprintf('  一致性分析完成: %d 个桩号\n', idx);
end


%% ====================================================================
%% ==================== 绘图函数 =====================================
%% ====================================================================

function plotSchemeAResults(scheme_A_results, output_dir)
if isempty(scheme_A_results), return; end

valid = scheme_A_results(~isnan([scheme_A_results.D0_error_pct]));
if isempty(valid), return; end

loads   = [valid.load_kN];
d0_errs = [valid.D0_error_pct];
ldcs    = [valid.LDC];

unique_loads = unique(loads);
mean_err = arrayfun(@(L) mean(d0_errs(loads==L)), unique_loads);
std_err  = arrayfun(@(L) std(d0_errs(loads==L)),  unique_loads);

fig = figure('Name','方案A：线弹性假设验证','Position',[100 100 1200 500]);

% 子图1：D0误差随荷载变化
subplot(1,3,1);
errorbar(unique_loads, mean_err, std_err, 'bo-', 'LineWidth', 2, 'MarkerSize', 8);
hold on;
plot([unique_loads(1), unique_loads(end)], [10, 10], 'r--', 'LineWidth', 1.5);
xlabel('FWD Load (kN)');
ylabel('D0 Prediction Error (%)');
title('Linear Elastic Prediction Error vs Load');
legend('Mean ± Std', '10% Threshold', 'Location', 'northwest');
grid on;

% 子图2：LDC分布
subplot(1,3,2);
mean_ldc = arrayfun(@(L) mean(ldcs(loads==L)), unique_loads);
bar(unique_loads, mean_ldc, 0.5, 'FaceColor', [0.3 0.6 0.9]);
hold on;
plot([unique_loads(1)-5, unique_loads(end)+5], [1.1, 1.1], 'r--', 'LineWidth', 1.5);
xlabel('FWD Load (kN)');
ylabel('Linear Deviation Coefficient (LDC)');
title('LDC: Nonlinearity Indicator');
text(unique_loads(end)-10, 1.12, 'LDC = 1.1 threshold', 'Color', 'r', 'FontSize', 8);
grid on;

% 子图3：线性假设成立比例
subplot(1,3,3);
n_valid_load = arrayfun(@(L) sum(loads==L), unique_loads);
n_pass_load  = arrayfun(@(L) sum([valid(loads==L).linear_elastic_valid]), unique_loads);
pass_rate = n_pass_load ./ n_valid_load * 100;
bar(unique_loads, pass_rate, 0.5, 'FaceColor', [0.3 0.8 0.4]);
xlabel('FWD Load (kN)');
ylabel('Pass Rate (%)');
title('Linear Elastic Assumption Pass Rate');
ylim([0 110]);
grid on;
for k = 1:length(unique_loads)
    text(unique_loads(k), pass_rate(k)+2, sprintf('%.0f%%', pass_rate(k)), ...
        'HorizontalAlignment','center', 'FontSize', 9);
end

sgtitle('Scheme A: Linear Elastic Assumption Validation via Multi-Load FWD');
saveas(fig, fullfile(output_dir, 'SchemeA_LinearElastic_Validation.png'));
fprintf('  📊 方案A图表已保存\n');
end


function plotSchemeBResults(consistency, output_dir)
if isempty(consistency), return; end

AC_CVs = [consistency.AC_CV];
BC_CVs = [consistency.BC_CV];
SB_CVs = [consistency.SB_CV];

fig = figure('Name','方案B：一致性分析','Position',[100 100 1200 500]);

% 子图1：CV分布箱线图
subplot(1,3,1);
boxplot([AC_CVs', BC_CVs', SB_CVs'], {'AC Layer', 'Base Layer', 'Subbase'});
hold on;
plot([0.5, 3.5], [15, 15], 'g--', 'LineWidth', 1.5);
plot([0.5, 3.5], [30, 30], 'r--', 'LineWidth', 1.5);
ylabel('CV (%)');
title('Modulus CV across Load Levels');
legend('CV=15% (High)', 'CV=30% (Low)', 'Location', 'northeast');
grid on;

% 子图2：可信度评级饼图
subplot(1,3,2);
reliabilities = {consistency.reliability};
n_high   = sum(strcmp(reliabilities, 'High'));
n_medium = sum(strcmp(reliabilities, 'Medium'));
n_low    = sum(strcmp(reliabilities, 'Low'));
pie([n_high, n_medium, n_low], {'High','Medium','Low'});
colormap(gca, [0.3 0.8 0.3; 1.0 0.8 0.0; 0.9 0.3 0.3]);
title(sprintf('Reliability Rating (N=%d stations)', length(consistency)));

% 子图3：各路段CV散点
subplot(1,3,3);
scatter(AC_CVs, BC_CVs, 60, 'bo', 'filled'); hold on;
scatter(AC_CVs, SB_CVs, 60, 'rs', 'filled');
xlabel('AC Layer CV (%)');
ylabel('Base/Subbase CV (%)');
title('Layer CV Correlation');
legend('Base Layer', 'Subbase', 'Location', 'best');
plot([0 80],[0 80],'k--','LineWidth',1);
grid on;

sgtitle('Scheme B: Multi-Load Consistency Analysis');
saveas(fig, fullfile(output_dir, 'SchemeB_Consistency_Analysis.png'));
fprintf('  📊 方案B图表已保存\n');
end


%% ====================================================================
%% ==================== 辅助函数 =====================================
%% ====================================================================

function input_data = buildInputData(row)
% 将CSV一行转换为系统标准 input_data 结构体

input_data = struct();
input_data.pavement_type      = determinePavementType(row.pavement_type{1});
input_data.pavement_type_name = row.pavement_type{1};
input_data.input_mode         = 'multi_load_validation';
input_data.name               = sprintf('%s_%s_%.0fkN', ...
    row.section_id{1}, row.station{1}, row.load_kN);

% 层厚
input_data.thickness = [row.thickness_AC_cm; row.thickness_BC_cm; row.thickness_SB_cm];

% 泊松比
input_data.poisson = [row.poisson_AC; row.poisson_BC; row.poisson_SB];

% 荷载参数
input_data.load_pressure = row.load_pressure_MPa;
input_data.load_radius   = row.load_radius_cm;

% 土基
input_data.subgrade_modulus = row.subgrade_modulus_MPa;

% 弯沉盆
% 改为动态读取（与sensor_offsets对应）：
sensor_cols = {'D0_mm','D23_mm','D53_mm','D69_mm','D85_mm','D116_mm','D153_mm'};
basin = zeros(1, length(sensor_cols));
for sc = 1:length(sensor_cols)
    if ismember(sensor_cols{sc}, row.Properties.VariableNames)
        basin(sc) = row.(sensor_cols{sc});
    end
end
input_data.deflection_basin    = basin;
input_data.measured_deflection = basin(1);  % D0

input_data.measured_deflection = row.D0_mm;
% 从CSV字段动态读取传感器位置
if ismember('sensor_offsets_cm', row.Properties.VariableNames) && strlength(row.sensor_offsets_cm) > 0
    offset_str = char(row.sensor_offsets_cm);
    input_data.sensor_offsets = str2double(strsplit(offset_str, ','))';
else
    input_data.sensor_offsets = [0, 23, 53, 69, 85, 116, 153];
end

deflection_cols = {'D0_mm','D23_mm','D53_mm','D69_mm','D85_mm','D116_mm','D153_mm'};
basin = zeros(1, length(deflection_cols));
for k = 1:length(deflection_cols)
    if ismember(deflection_cols{k}, row.Properties.VariableNames)
        basin(k) = row.(deflection_cols{k});
    end
end
input_data.deflection_basin    = basin;
input_data.measured_deflection = basin(1);

input_data.boundary_type       = 'fixed';

% 模量约束（调用原有系统的约束逻辑）
input_data.modulus_constraints = getDefaultConstraints(row.pavement_type{1}, row.D0_mm);
end

function ptype = determinePavementType(type_str)
if contains(lower(type_str), 'semi')
    ptype = 2;
else
    ptype = 1;  % flexible
end
end

function constraints = getDefaultConstraints(ptype_str, D0)
constraints = struct();
if contains(lower(ptype_str), 'semi')
    constraints.surface_min = 2000; constraints.surface_max = 10000;
    constraints.base_min    = 2000; constraints.base_max    = 35000;
    constraints.subbase_min = 500;  constraints.subbase_max = 8000;
else
    if D0 > 0.35
        constraints.surface_min = 800;  constraints.surface_max = 5000;
        constraints.base_min    = 150;  constraints.base_max    = 1500;
        constraints.subbase_min = 60;   constraints.subbase_max = 500;
    else
        constraints.surface_min = 1200; constraints.surface_max = 6500;
        constraints.base_min    = 300;  constraints.base_max    = 2000;
        constraints.subbase_min = 100;  constraints.subbase_max = 700;
    end
end
end

function params = constructPDEParams_local(input_data, modulus)
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
params.pavement_type     = input_data.pavement_type;
params.boundary_type     = input_data.boundary_type;
end

function pde_results = performPDE_local(params, input_data)
load_params = struct('load_pressure', params.load_pressure, ...
                     'load_radius',   params.load_radius);
bc = struct('modeling_type',    params.subgrade_modeling, ...
            'subgrade_modulus', params.subgrade_modulus, ...
            'soil_modulus',     params.subgrade_modulus, ...
            'sensor_offsets',   params.sensor_offsets, ...
            'boundary_type',    params.boundary_type);
try
    pde_results = roadPDEModelingABAQUSCalibrated(params, load_params, bc);
catch
    pde_results = struct('success', false, 'D0', input_data.measured_deflection, ...
                         'deflections', input_data.deflection_basin);
end
end

function D0 = getD0_local(pde_results)
if isfield(pde_results,'D0') && pde_results.D0 > 0
    D0 = pde_results.D0;
elseif isfield(pde_results,'deflections') && ~isempty(pde_results.deflections)
    D0 = pde_results.deflections(1);
else
    D0 = 0.5;
end
end

function saveBackcalcResults(results, filepath)
n = length(results);
T = table();
T.section_id    = {results.section_id}';
T.station       = {results.station}';
T.load_kN       = [results.load_kN]';
T.AC_MPa        = [results.AC_MPa]';
T.BC_MPa        = [results.BC_MPa]';
T.SB_MPa        = [results.SB_MPa]';
T.SG_MPa        = [results.SG_MPa]';
T.D0_error_pct  = [results.D0_error_pct]';
T.converged     = [results.converged]';
T.iterations    = [results.iterations]';
writetable(T, filepath);
end

function saveSchemeAResults(results, filepath)
if isempty(results), return; end
n = length(results);
T = table();
T.section_id    = {results.section_id}';
T.station       = {results.station}';
T.load_kN       = [results.load_kN]';
T.AC_MPa        = [results.AC_MPa]';
T.BC_MPa        = [results.BC_MPa]';
T.D0_error_pct  = [results.D0_error_pct]';
T.rmse_mm       = [results.rmse_mm]';
T.LDC           = [results.LDC]';
T.linear_elastic_valid = [results.linear_elastic_valid]';
writetable(T, filepath);
end

function saveConsistencyResults(consistency, filepath)
if isempty(consistency), return; end
T = table();
T.section_id = {consistency.section_id}';
T.station    = {consistency.station}';
T.n_valid    = [consistency.n_valid]';
T.AC_mean    = [consistency.AC_mean]';
T.AC_CV_pct  = [consistency.AC_CV]';
T.BC_mean    = [consistency.BC_mean]';
T.BC_CV_pct  = [consistency.BC_CV]';
T.SB_mean    = [consistency.SB_mean]';
T.SB_CV_pct  = [consistency.SB_CV]';
T.reliability = {consistency.reliability}';
writetable(T, filepath);
end

function printSummary(scheme_A_results, scheme_B_consistency)
fprintf('\n╔══════════════════════════════════════════════════════════════╗\n');
fprintf('║                    实验汇总                                  ║\n');
fprintf('╚══════════════════════════════════════════════════════════════╝\n\n');

% 方案A统计
valid_A = scheme_A_results(~isnan([scheme_A_results.D0_error_pct]));
if ~isempty(valid_A)
    pass_rate = mean([valid_A.linear_elastic_valid]) * 100;
    fprintf('  【方案A：线弹性假设验证】\n');
    fprintf('    有效预测组数: %d\n', length(valid_A));
    fprintf('    D0误差均值:   %.2f%%\n', mean([valid_A.D0_error_pct]));
    fprintf('    RMSE均值:     %.4f mm\n', mean([valid_A.rmse_mm]));
    fprintf('    LDC均值:      %.3f\n', mean([valid_A.LDC]));
    fprintf('    线弹性成立率: %.1f%%\n\n', pass_rate);
end

% 方案B统计
if ~isempty(scheme_B_consistency)
    reliabilities = {scheme_B_consistency.reliability};
    fprintf('  【方案B：多荷载一致性分析】\n');
    fprintf('    分析桩号数:   %d\n', length(scheme_B_consistency));
    fprintf('    可信度High:   %d (%.1f%%)\n', sum(strcmp(reliabilities,'High')), ...
        mean(strcmp(reliabilities,'High'))*100);
    fprintf('    可信度Medium: %d (%.1f%%)\n', sum(strcmp(reliabilities,'Medium')), ...
        mean(strcmp(reliabilities,'Medium'))*100);
    fprintf('    可信度Low:    %d (%.1f%%)\n', sum(strcmp(reliabilities,'Low')), ...
        mean(strcmp(reliabilities,'Low'))*100);
    fprintf('    AC层CV均值:   %.1f%%\n', mean([scheme_B_consistency.AC_CV]));
    fprintf('    基层CV均值:   %.1f%%\n', mean([scheme_B_consistency.BC_CV]));
    fprintf('    底基层CV均值: %.1f%%\n\n', mean([scheme_B_consistency.SB_CV]));
end
end

function config = getDefaultValidationConfig()
config = struct();
config.ppo_backcalculation.max_episodes        = 150;
config.ppo_backcalculation.max_steps_per_episode = 15;
config.ppo_backcalculation.early_stop_patience = 20;
config.ppo_backcalculation.learning_rate       = 0.001;
config.backcalculation.convergence_threshold   = 0.05;
config.llm_guidance.enabled                    = false;  % 批量时关LLM加速
config.llm_guidance.use_for_initial_estimate   = false;
config.llm_guidance.use_for_optimization_guidance = false;
config.llm_guidance.guidance_interval          = 10;
config.llm_guidance.model                      = 'deepseek';
config.deepseek.api_key  = '';
config.deepseek.base_url = 'https://api.deepseek.com/v1';
config.deepseek.model    = 'deepseek-chat';
config.deepseek.max_tokens  = 2000;
config.deepseek.temperature = 0.1;
config.deepseek.timeout     = 30;
config.ollama.base_url   = 'http://localhost:11434';
config.ollama.model      = 'qwen2.5:7b';
config.ollama.temperature = 0.1;
config.ollama.timeout    = 60;
end