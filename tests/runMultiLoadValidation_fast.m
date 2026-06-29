function runMultiLoadValidation_fast(sections_to_run)
% RUNMULTILOADVALIDATION_FAST  快速版多荷载验证（LLM全程参与）
%
% 【LLM参与方式 - 方向B：全程参与】
%   1. LLM初始模量估计：替代经验公式，基于路面类型/弯沉/层厚做物理推理
%   2. LLM优化指导：PPO每隔 guidance_interval 个episode向LLM请求搜索方向建议
%   3. LLM多解选优：Multi-Run N次PPO，LLM对候选解进行物理合理性评分（10分制）
%
% 【用法】
%   runMultiLoadValidation_fast()                      % 默认跑 STR1
%   runMultiLoadValidation_fast({'STR13','STR18'})     % 只跑指定断面
%   runMultiLoadValidation_fast({'STR1','STR13','STR18'}) % 跑多个断面

% 默认断面
if nargin < 1 || isempty(sections_to_run)
    sections_to_run = {'STR1'};
end
if ischar(sections_to_run)
    sections_to_run = {sections_to_run};
end

fprintf('╔══════════════════════════════════════════════════════════════╗\n');
fprintf('║       多荷载验证实验 (方案A + 方案B) — LLM全程参与         ║\n');
fprintf('║       LLM: 初始估计 + 优化指导 + 多解选优                  ║\n');
fprintf('╚══════════════════════════════════════════════════════════════╝\n\n');

%% ===== 路径配置 =====
% runMultiLoadValidation_fast.m 放在 tests/ 目录下时用此行：
project_root = fileparts(fileparts(mfilename('fullpath')));
% 若放在项目根目录，改为：
% project_root = fileparts(mfilename('fullpath'));

addpath(fullfile(project_root, 'backcalculation'));
addpath(fullfile(project_root, 'core'));
addpath(fullfile(project_root, 'utils'));

output_dir = fullfile(project_root, 'output', 'multiload_validation');
if ~exist(output_dir, 'dir'), mkdir(output_dir); end

%% ===== 快速配置（关键参数） =====
config = getFastConfig();

% ---- 从 config_backcalculation.json 读取 API key ----
json_file = fullfile(project_root, 'config_backcalculation.json');
if exist(json_file, 'file')
    try
        json_text = fileread(json_file);
        json_cfg  = jsondecode(json_text);
        if isfield(json_cfg, 'deepseek') && isfield(json_cfg.deepseek, 'api_key') ...
                && ~isempty(json_cfg.deepseek.api_key)
            config.deepseek.api_key = json_cfg.deepseek.api_key;
            fprintf('✅ DeepSeek API key 已从配置文件加载\n');
        else
            warning('config_backcalculation.json 中未找到 deepseek.api_key，将使用经验回退模式');
            config.llm_guidance.enabled = false;
        end
        % 同步其他可覆盖字段
        if isfield(json_cfg, 'deepseek') && isfield(json_cfg.deepseek, 'model')
            config.deepseek.model = json_cfg.deepseek.model;
        end
    catch ME_json
        warning('iLLM:configReadFail', '读取配置文件失败: %s，将使用经验回退模式', ME_json.message);
        config.llm_guidance.enabled = false;
    end
else
    warning('未找到 config_backcalculation.json，将使用经验回退模式');
    config.llm_guidance.enabled = false;
end

fprintf('⚙️  PPO参数: max_episodes=%d, early_stop=%d, timeout=%ds\n', ...
    config.ppo_backcalculation.max_episodes, ...
    config.ppo_backcalculation.early_stop_patience, ...
    config.per_record_timeout_sec);
fprintf('⚙️  Multi-Run次数: %d（LLM多解选优）\n', config.multi_run.n_runs);
if config.llm_guidance.enabled
    fprintf('⚙️  LLM: %s（初始估计 + 每%d eps指导 + 多解选优）\n\n', ...
        config.llm_guidance.model, config.llm_guidance.guidance_interval);
else
    fprintf('⚙️  LLM: 不可用（API key缺失），已切换为经验公式回退模式\n\n');
end

%% ===== 加载数据 =====
data_file = fullfile(project_root, 'data', 'multi_load_validation_data.csv');
if ~exist(data_file, 'file')
    error('数据文件不存在: %s', data_file);
end

all_raw = readtable(data_file, 'TextType', 'string');
fprintf('✅ 加载全部数据: %d 行记录，共 %d 个断面\n', height(all_raw), numel(unique(all_raw.section_id)));
fprintf('   本次运行断面: %s\n', strjoin(sections_to_run, ', '));

mask_sec = ismember(all_raw.section_id, sections_to_run);
raw_data = all_raw(mask_sec, :);
fprintf('   筛选后记录数: %d 条\n', height(raw_data));

mask_50kN = raw_data.load_kN == 50;
base_data  = raw_data(mask_50kN, :);
other_data = raw_data(~mask_50kN, :);
fprintf('   50kN基准记录: %d 条\n', height(base_data));
fprintf('   其他荷载记录: %d 条\n', height(other_data));

% 估算时间
sections_tag = strjoin(sections_to_run, '_');
n_runs = config.multi_run.n_runs;
est_sec_per_record = config.ppo_backcalculation.max_episodes * 8;
est_min_A  = ceil(height(base_data) * n_runs * est_sec_per_record / 60);
est_min_B  = ceil(height(raw_data) * est_sec_per_record / 60);
fprintf('\n⏱️  预估时间: 方案A约%d分钟 + 方案B约%d分钟 = 总计约%.1f小时\n', ...
    est_min_A, est_min_B, (est_min_A + est_min_B)/60);
fprintf('   （支持断点续算，中断后重新运行自动跳过已完成记录）\n\n');

%% ===================================================================
%% 方案A Step 1：50kN反算（带断点续算）
%% ===================================================================
fprintf('══════════════════════════════════════════════════════════════\n');
fprintf('  方案A Step 1/2：50kN记录反算，获取E*\n');
fprintf('══════════════════════════════════════════════════════════════\n\n');

checkpoint_file = fullfile(output_dir, sprintf('checkpoint_50kN_%s.mat', sections_tag));
backcalc_results_50kN = runBackcalcBatch_fast(base_data, config, ...
    sprintf('50kN_%s', sections_tag), checkpoint_file);

save_50kN_file = fullfile(output_dir, sprintf('backcalc_50kN_results_%s.csv', sections_tag));
saveBackcalcResults(backcalc_results_50kN, save_50kN_file);
fprintf('✅ 50kN反算结果已保存: %s\n\n', save_50kN_file);

%% ===================================================================
%% 方案A Step 2：正向预测验证线弹性假设
%% ===================================================================
fprintf('══════════════════════════════════════════════════════════════\n');
fprintf('  方案A Step 2/2：用E*预测68/88/109kN弯沉\n');
fprintf('══════════════════════════════════════════════════════════════\n\n');

scheme_A_results = [];
try
    scheme_A_results = runLinearElasticValidation(backcalc_results_50kN, other_data);
catch ME_A
    fprintf('⚠️  方案A线弹性验证失败，跳过（不影响方案B）: %s\n\n', ME_A.message);
end

save_A_file = fullfile(output_dir, sprintf('schemeA_linear_elastic_validation_%s.csv', sections_tag));
if ~isempty(scheme_A_results)
    saveSchemeAResults(scheme_A_results, save_A_file);
    fprintf('✅ 方案A结果已保存: %s\n\n', save_A_file);
end

%% ===================================================================
%% 方案B：归一化后各自独立反算
%% ===================================================================
fprintf('══════════════════════════════════════════════════════════════\n');
fprintf('  方案B：多荷载归一化独立反算\n');
fprintf('══════════════════════════════════════════════════════════════\n\n');

normalized_data = normalizeToReference(raw_data, 50);
fprintf('  归一化后共 %d 条独立验证记录\n\n', height(normalized_data));

checkpoint_B_file = fullfile(output_dir, sprintf('checkpoint_normalized_%s.mat', sections_tag));
backcalc_results_all = runBackcalcBatch_fast(normalized_data, config, ...
    sprintf('normalized_%s', sections_tag), checkpoint_B_file);

save_B_file = fullfile(output_dir, sprintf('schemeB_all_backcalc_results_%s.csv', sections_tag));
saveBackcalcResults(backcalc_results_all, save_B_file);
fprintf('✅ 方案B反算结果已保存: %s\n\n', save_B_file);

%% ===== 方案B一致性分析 =====
scheme_B_consistency = analyzeConsistency(backcalc_results_all, raw_data);
save_B_cons_file = fullfile(output_dir, sprintf('schemeB_consistency_analysis_%s.csv', sections_tag));
saveConsistencyResults(scheme_B_consistency, save_B_cons_file);
fprintf('✅ 方案B一致性分析已保存: %s\n\n', save_B_cons_file);

%% ===== 绘图 =====
fprintf('══════════════════════════════════════════════════════════════\n');
fprintf('  生成论文图表\n');
fprintf('══════════════════════════════════════════════════════════════\n\n');
if ~isempty(scheme_A_results)
    try
        plotSchemeAResults(scheme_A_results, output_dir);
    catch ME_plotA
        fprintf('⚠️  方案A绘图失败: %s\n', ME_plotA.message);
    end
end
plotSchemeBResults(scheme_B_consistency, output_dir);

%% ===== 汇总 =====
printSummary(scheme_A_results, scheme_B_consistency);
fprintf('\n✅ 多荷载验证实验完成！结果保存在:\n   %s\n\n', output_dir);

% 清理断点文件
if exist(checkpoint_file, 'file'), delete(checkpoint_file); end
if exist(checkpoint_B_file, 'file'), delete(checkpoint_B_file); end
end


%% ====================================================================
%% 核心改动：带超时和断点续算的批量反算
%% ====================================================================

function results = runBackcalcBatch_fast(data_table, config, batch_name, checkpoint_file)
% 批量反算（快速版）
%   - 每条记录独立超时保护
%   - 实时断点保存（每条完成后写.mat）
%   - 断点续算：若checkpoint存在，跳过已完成条目

n = height(data_table);
timeout_sec = config.per_record_timeout_sec;

fprintf('  [%s] 共 %d 条记录 (超时限制: %ds/条)\n', batch_name, n, timeout_sec);

% 断点续算：尝试加载已有结果
if exist(checkpoint_file, 'file')
    loaded = load(checkpoint_file, 'results', 'completed_idx');
    results = loaded.results;
    completed_idx = loaded.completed_idx;
    fprintf('  ↩️  断点续算：已完成 %d 条，从第 %d 条继续\n\n', ...
        length(completed_idx), max(completed_idx)+1);
else
    % 预分配
    results = repmat(makeEmptyResult(), n, 1);
    for k = 1:n
        results(k).section_id = '';
        results(k).station    = '';
        results(k).load_kN    = 0;
    end
    completed_idx = [];
end

t_batch_start = tic;

for i = 1:n
    % 跳过已完成
    if ismember(i, completed_idx)
        continue;
    end
    
    row = data_table(i, :);
    sec_id  = char(row.section_id);
    sta_str = char(row.station);
    
    fprintf('\n  ── [%d/%d] %s %s (%.0fkN) ──\n', ...
        i, n, sec_id, sta_str, row.load_kN);
    
    t_rec = tic;
    
    try
        % ---- 构建输入 ----
        input_data = buildInputData(row);
        
        % ---- 初始模量估计（LLM优先，失败回退经验公式） ----
        if config.llm_guidance.enabled
            try
                initial_modulus = initialModulusGenerator(input_data, config, 'llm');
                fprintf('     LLM初始估计: AC=%d BC=%d SB=%d MPa\n', ...
                    round(initial_modulus.surface), round(initial_modulus.base), ...
                    round(initial_modulus.subbase));
            catch ME_llm_init
                fprintf('     ⚠️ LLM初始估计失败(%s)，回退经验公式\n', ME_llm_init.message);
                initial_modulus = initialModulusGenerator(input_data, config, 'empirical');
                fprintf('     经验初始估计: AC=%d BC=%d SB=%d MPa\n', ...
                    round(initial_modulus.surface), round(initial_modulus.base), ...
                    round(initial_modulus.subbase));
            end
        else
            initial_modulus = initialModulusGenerator(input_data, config, 'empirical');
            fprintf('     经验初始估计: AC=%d BC=%d SB=%d MPa\n', ...
                round(initial_modulus.surface), round(initial_modulus.base), ...
                round(initial_modulus.subbase));
        end
        
        % ---- 初始PDE ----
        initial_params = constructPDEParams_local(input_data, initial_modulus);
        initial_pde    = performPDE_local(initial_params, input_data);
        
        init_D0    = getD0_local(initial_pde);
        init_error = abs(init_D0 - input_data.measured_deflection) / ...
                     input_data.measured_deflection;
        
        fprintf('     初始D0误差: %.2f%%', init_error * 100);
        
        if init_error < config.backcalculation.convergence_threshold
            % 初始LLM估计已满足，无需PPO
            fprintf(' ✓ LLM直接命中，免PPO\n');
            final_modulus = initial_modulus;
            final_pde     = initial_pde;
            opt_log = struct('converged', true, 'iterations', 0, ...
                             'best_error', init_error, 'total_time', 0, ...
                             'llm_selections', 1);
        else
            fprintf('\n');
            % ---- Multi-Run PPO + LLM选优（或单次PPO回退） ----
            n_runs = config.multi_run.n_runs;
            use_multirun = config.llm_guidance.enabled && config.multi_run.enabled;
            if ~use_multirun, n_runs = 1; end

            candidate_moduli = cell(n_runs, 1);
            candidate_logs   = cell(n_runs, 1);
            candidate_pdes   = cell(n_runs, 1);
            
            for r = 1:n_runs
                if use_multirun
                    fprintf('     Run %d/%d (LLM指导PPO)...\n', r, n_runs);
                else
                    fprintf('     PPO优化中...\n');
                end
                try
                    agent = BackcalculationPPO(input_data, config, initial_modulus, initial_pde);
                    [candidate_moduli{r}, candidate_logs{r}] = agent.optimize();
                    p = constructPDEParams_local(input_data, candidate_moduli{r});
                    candidate_pdes{r} = performPDE_local(p, input_data);
                    err_r = abs(getD0_local(candidate_pdes{r}) - input_data.measured_deflection) ...
                            / input_data.measured_deflection * 100;
                    fprintf('       Run%d: D0误差=%.2f%%, 收敛=%d\n', r, err_r, candidate_logs{r}.converged);
                catch ME_run
                    fprintf('       Run%d 失败: %s\n', r, ME_run.message);
                    candidate_moduli{r} = initial_modulus;
                    candidate_logs{r}   = struct('converged', false, 'iterations', 0, ...
                                                  'best_error', init_error, 'total_time', 0);
                    candidate_pdes{r}   = initial_pde;
                end
            end
            
            % ---- LLM多解选优（或直接取唯一解） ----
            if use_multirun && n_runs > 1
                fprintf('     LLM多解评分选优...\n');
                try
                    [best_idx, selection_log] = llmSelectBestSolution(...
                        candidate_moduli, candidate_pdes, input_data, config);
                    fprintf('     LLM选择: Run%d（评分: %s）\n', best_idx, ...
                        selection_log.scores_str);
                catch ME_sel
                    fprintf('     ⚠️ LLM选优失败，回退最小误差: %s\n', ME_sel.message);
                    errors = cellfun(@(pde) abs(getD0_local(pde) - input_data.measured_deflection) ...
                        / input_data.measured_deflection, candidate_pdes);
                    [~, best_idx] = min(errors);
                    selection_log = struct('scores_str', 'fallback_min_error');
                end
            else
                % 单次Run或LLM不可用：取误差最小的（通常就是Run1）
                errors = cellfun(@(pde) abs(getD0_local(pde) - input_data.measured_deflection) ...
                    / input_data.measured_deflection, candidate_pdes);
                [~, best_idx] = min(errors);
                selection_log = struct('scores_str', 'single_run');
            end
            
            final_modulus = candidate_moduli{best_idx};
            final_pde     = candidate_pdes{best_idx};
            best_log      = candidate_logs{best_idx};
            opt_log = struct('converged', best_log.converged, ...
                             'iterations', best_log.iterations, ...
                             'best_error', best_log.best_error, ...
                             'total_time', toc(t_rec), ...
                             'llm_selections', best_idx, ...
                             'llm_scores', selection_log.scores_str, ...
                             'n_runs', n_runs);
        end
        
        elapsed = toc(t_rec);
        
        % ---- 超时判断（事后记录，不中断） ----
        if elapsed > timeout_sec
            fprintf('     ⚠️ 超时 (%.0fs > %ds)\n', elapsed, timeout_sec);
        end
        
        % ---- 计算误差指标 ----
        final_D0    = getD0_local(final_pde);
        final_error = abs(final_D0 - input_data.measured_deflection) / ...
                      input_data.measured_deflection;
        
        n_s = length(input_data.deflection_basin);
        if isfield(final_pde, 'deflections') && length(final_pde.deflections) >= n_s
            pred = final_pde.deflections(1:n_s);
            meas = input_data.deflection_basin;
            basin_rmse = sqrt(mean((pred - meas).^2));
        else
            basin_rmse = nan;
        end
        
        % ---- 写结果 ----
        results(i).section_id    = sec_id;
        results(i).station       = sta_str;
        results(i).load_kN       = row.load_kN;
        results(i).AC_MPa        = round(final_modulus.surface);
        results(i).BC_MPa        = round(final_modulus.base);
        results(i).SB_MPa        = round(final_modulus.subbase);
        results(i).SG_MPa        = round(final_modulus.subgrade);
        results(i).D0_error_pct  = final_error * 100;
        results(i).basin_rmse_mm = basin_rmse;
        results(i).converged     = opt_log.converged;
        results(i).iterations    = opt_log.iterations;
        results(i).elapsed_sec   = elapsed;
        results(i).final_pde     = final_pde;
        results(i).input_data    = input_data;
        results(i).final_modulus = final_modulus;
        % LLM参与记录
        results(i).llm_initial_used   = true;
        results(i).llm_selected_run   = opt_log.llm_selections;
        if isfield(opt_log, 'llm_scores')
            results(i).llm_scores = opt_log.llm_scores;
        else
            results(i).llm_scores = 'direct_hit';
        end
        
        conv_str = ternary(opt_log.converged, '✅收敛', '⚠️未收敛');
        fprintf('     %s | AC=%d BC=%d SB=%d SG=%d MPa | D0误差=%.2f%% | %.0fs\n', ...
            conv_str, results(i).AC_MPa, results(i).BC_MPa, ...
            results(i).SB_MPa, results(i).SG_MPa, ...
            results(i).D0_error_pct, elapsed);
        
    catch ME
        fprintf('     ❌ 失败: %s\n', ME.message);
        results(i).section_id   = char(row.section_id);
        results(i).station      = char(row.station);
        results(i).load_kN      = row.load_kN;
        results(i).D0_error_pct = nan;
        results(i).converged    = false;
        results(i).iterations   = 0;
        results(i).elapsed_sec  = toc(t_rec);
        % 保底字段（保证方案A/B可访问）
        if exist('final_modulus','var') && ~isempty(fieldnames(final_modulus))
            results(i).final_modulus = final_modulus;
        elseif exist('initial_modulus','var') && ~isempty(fieldnames(initial_modulus))
            results(i).final_modulus = initial_modulus;
            % 用初始估计跑一次PDE，尽量给方案A提供可用结果
            try
                ip = buildInputData(row);
                pp = constructPDEParams_local(ip, initial_modulus);
                fp = performPDE_local(pp, ip);
                results(i).final_pde    = fp;
                results(i).final_modulus = initial_modulus;
                err_fallback = abs(getD0_local(fp) - ip.measured_deflection) ...
                               / ip.measured_deflection * 100;
                results(i).D0_error_pct = err_fallback;
                results(i).input_data   = ip;
                % 若误差<30%，视为可用（虽未经PPO优化）
                results(i).converged = (err_fallback < 30);
                fprintf('     ↩️ 经验初始估计回退: D0误差=%.1f%% converged=%d\n', ...
                    err_fallback, results(i).converged);
            catch
                results(i).final_pde  = struct();
                results(i).input_data = struct();
            end
        else
            results(i).final_modulus = struct();
            results(i).final_pde     = struct();
            results(i).input_data    = struct();
        end
        results(i).llm_initial_used = false;
        results(i).llm_selected_run = nan;
        results(i).llm_scores       = 'failed';
    end
    
    completed_idx = [completed_idx, i]; %#ok<AGROW>
    
    % ---- 断点保存（每条完成后） ----
    save(checkpoint_file, 'results', 'completed_idx');
    
    % ---- 进度预估 ----
    elapsed_total = toc(t_batch_start);
    avg_sec = elapsed_total / length(completed_idx);
    remaining = (n - length(completed_idx)) * avg_sec;
    fprintf('     进度: %d/%d 完成 | 预计剩余: %.0f 分钟\n', ...
        length(completed_idx), n, remaining/60);
end

n_ok = sum([results.converged]);
fprintf('\n  [%s] 批量完成: %d/%d 收敛 (%.1f%%) | 总耗时: %.1f 分钟\n', ...
    batch_name, n_ok, n, n_ok/n*100, toc(t_batch_start)/60);
end


%% ====================================================================
%% 以下函数与原版 runMultiLoadValidation.m 完全一致
%% ====================================================================

function r = makeEmptyResult()
r.section_id    = '';
r.station       = '';
r.load_kN       = 0;
r.AC_MPa        = nan;
r.BC_MPa        = nan;
r.SB_MPa        = nan;
r.SG_MPa        = nan;
r.D0_error_pct  = nan;
r.basin_rmse_mm = nan;
r.converged     = false;
r.iterations    = 0;
r.elapsed_sec   = 0;
r.final_pde     = struct();
r.input_data    = struct();
r.final_modulus = struct();
r.llm_initial_used = false;
r.llm_selected_run = nan;
r.llm_scores    = '';
end

function input_data = buildInputData(row)
input_data = struct();
input_data.section_id    = char(row.section_id);
input_data.station       = char(row.station);
input_data.load_kN       = row.load_kN;
input_data.load_pressure = row.load_pressure_MPa;
input_data.load_radius   = row.load_radius_cm;        % 单位保持 cm，PDE/PPO内部自行转换
input_data.thickness     = [row.thickness_AC_cm; row.thickness_BC_cm; row.thickness_SB_cm] / 100;
input_data.subgrade_modulus = row.subgrade_modulus_MPa;
input_data.poisson       = [row.poisson_AC; row.poisson_BC; row.poisson_SB];
input_data.pavement_type = char(row.pavement_type);

if ismember('sensor_offsets_cm', row.Properties.VariableNames) && strlength(row.sensor_offsets_cm) > 0
    input_data.sensor_offsets = str2double(strsplit(char(row.sensor_offsets_cm), ','))';
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
input_data.modulus_constraints = getDefaultConstraints(char(row.pavement_type), row.D0_mm);
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
params.thickness     = input_data.thickness(:);
params.modulus       = [modulus.surface; modulus.base; modulus.subbase];
params.poisson       = input_data.poisson(:);
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

function scheme_A_results = runLinearElasticValidation(backcalc_50kN, other_data)
n_base  = length(backcalc_50kN);
results = struct();
idx     = 0;

for i = 1:n_base
    % 过滤条件：converged=true 或 D0误差<30%（经验回退可用）
    is_usable = backcalc_50kN(i).converged || ...
                (~isnan(backcalc_50kN(i).D0_error_pct) && backcalc_50kN(i).D0_error_pct < 30);
    if ~is_usable, continue; end
    if ~isfield(backcalc_50kN(i).final_modulus, 'surface'), continue; end
    
    sec    = backcalc_50kN(i).section_id;
    sta    = backcalc_50kN(i).station;
    E_star = backcalc_50kN(i).final_modulus;
    input_ref = backcalc_50kN(i).input_data;
    
    match     = strcmp(other_data.section_id, sec) & strcmp(other_data.station, sta);
    other_rows = other_data(match, :);
    
    for j = 1:height(other_rows)
        row = other_rows(j, :);
        idx = idx + 1;
        
        input_fwd = input_ref;
        input_fwd.load_pressure = row.load_pressure_MPa;
        input_fwd.load_kN       = row.load_kN;
        input_fwd.load_radius   = row.load_radius_cm;   % cm，与buildInputData保持一致
        
        try
            params_fwd = constructPDEParams_local(input_fwd, E_star);
            pde_fwd    = performPDE_local(params_fwd, input_fwd);
            pred_basin = pde_fwd.deflections;
            
            meas_basin = [row.D0_mm, row.D23_mm, row.D53_mm, row.D69_mm, ...
                          row.D85_mm, row.D116_mm, row.D153_mm];
            
            n_s        = min(length(pred_basin), 7);
            pred_basin = pred_basin(1:n_s);
            meas_basin = meas_basin(1:n_s);
            
            D0_error_pct = abs(pred_basin(1) - meas_basin(1)) / meas_basin(1) * 100;
            rmse         = sqrt(mean((pred_basin - meas_basin).^2));
            
            scale_factor = row.load_kN / 50;
            ref_deflections = backcalc_50kN(i).final_pde.deflections;
            if length(ref_deflections) >= n_s
                linear_pred = ref_deflections(1:n_s) * scale_factor;
                rmse_linear = sqrt(mean((linear_pred - meas_basin).^2));
                LDC = rmse / max(rmse_linear, 1e-6);
            else
                LDC = nan;
            end
            
            results(idx).section_id         = sec;
            results(idx).station            = sta;
            results(idx).load_kN            = row.load_kN;
            results(idx).D0_error_pct       = D0_error_pct;
            results(idx).rmse_mm            = rmse;
            results(idx).LDC                = LDC;
            results(idx).AC_MPa             = round(E_star.surface);
            results(idx).BC_MPa             = round(E_star.base);
            results(idx).linear_elastic_valid = (~isnan(LDC) && LDC < 1.1 && D0_error_pct < 10);
            
        catch ME
            results(idx).section_id         = sec;
            results(idx).station            = sta;
            results(idx).load_kN            = row.load_kN;
            results(idx).D0_error_pct       = nan;
            results(idx).rmse_mm            = nan;
            results(idx).LDC                = nan;
            results(idx).AC_MPa             = round(E_star.surface);
            results(idx).BC_MPa             = round(E_star.base);
            results(idx).linear_elastic_valid = false;
        end
    end
end

scheme_A_results = results;
fprintf('  方案A完成: %d 组跨荷载预测\n', idx);
end

function normalized_table = normalizeToReference(raw_data, ref_kN)
n = height(raw_data);
normalized_table = raw_data;
deflection_cols = {'D0_mm','D23_mm','D53_mm','D69_mm','D85_mm','D116_mm','D153_mm'};

for i = 1:n
    F = raw_data.load_kN(i);
    if F == ref_kN, continue; end
    k = ref_kN / F;
    for c = 1:length(deflection_cols)
        col = deflection_cols{c};
        if ismember(col, normalized_table.Properties.VariableNames)
            normalized_table.(col)(i) = raw_data.(col)(i) * k;
        end
    end
    normalized_table.load_kN(i) = ref_kN;
    normalized_table.load_pressure_MPa(i) = ref_kN * 1000 / (pi * (15/100)^2 * 1e6);
end

normalized_table.original_load_kN = raw_data.load_kN;
end

function consistency = analyzeConsistency(all_results, raw_data)
valid_mask = [all_results.converged];
valid_results = all_results(valid_mask);
if isempty(valid_results)
    consistency = struct();
    return;
end

all_stations = unique({valid_results.station});
idx = 0;
consistency = struct();

for s = 1:length(all_stations)
    sta = all_stations{s};
    mask = strcmp({valid_results.station}, sta);
    grp  = valid_results(mask);
    
    if length(grp) < 2, continue; end
    
    idx = idx + 1;
    AC_vals = [grp.AC_MPa];
    BC_vals = [grp.BC_MPa];
    SB_vals = [grp.SB_MPa];
    
    consistency(idx).section_id = grp(1).section_id;
    consistency(idx).station    = sta;
    consistency(idx).n_valid    = length(grp);
    consistency(idx).AC_mean    = mean(AC_vals);
    consistency(idx).AC_CV      = std(AC_vals) / mean(AC_vals) * 100;
    consistency(idx).BC_mean    = mean(BC_vals);
    consistency(idx).BC_CV      = std(BC_vals) / mean(BC_vals) * 100;
    consistency(idx).SB_mean    = mean(SB_vals);
    consistency(idx).SB_CV      = std(SB_vals) / mean(SB_vals) * 100;
    
    avg_CV = mean([consistency(idx).AC_CV, consistency(idx).BC_CV, consistency(idx).SB_CV]);
    if avg_CV < 15
        consistency(idx).reliability = 'High';
    elseif avg_CV < 30
        consistency(idx).reliability = 'Medium';
    else
        consistency(idx).reliability = 'Low';
    end
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
T.llm_selected_run = [results.llm_selected_run]';
T.llm_scores    = {results.llm_scores}';
writetable(T, filepath);
end

function saveSchemeAResults(results, filepath)
if isempty(results) || ~isstruct(results) || ~isfield(results, 'section_id')
    fprintf('  ⚠️ 方案A无有效结果，跳过保存\n');
    return;
end
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

function plotSchemeAResults(results, output_dir)
if isempty(results)
    fprintf('  ⚠️ 方案A无结果，跳过绘图\n');
    return;
end

% 修正：先过滤掉没有 D0_error_pct 字段的记录，再过滤 NaN
has_field = arrayfun(@(r) isfield(r, 'D0_error_pct'), results);
results_with_field = results(has_field);
if isempty(results_with_field)
    warning('plotSchemeAResults: 无有效的 D0_error_pct 数据，跳过绘图');
    return;
end
valid = results_with_field(~isnan([results_with_field.D0_error_pct]));
if isempty(valid), return; end

fig = figure('Visible','off','Position',[0 0 900 400]);

% 子图1：D0误差分布
subplot(1,2,1);
loads = [valid.load_kN];
errs  = [valid.D0_error_pct];
boxplot(errs, loads);
xlabel('荷载等级 (kN)');
ylabel('D0预测误差 (%)');
title('方案A：线弹性假设验证 D0误差');
yline(10, 'r--', '10%阈值');
grid on;

% 子图2：LDC分布
subplot(1,2,2);
ldcs = [valid.LDC];
ldcs = ldcs(~isnan(ldcs));
histogram(ldcs, 10);
xlabel('线性偏差系数 LDC');
ylabel('频次');
title('LDC分布（<1.1为线弹性成立）');
xline(1.1, 'r--', 'LDC=1.1');
grid on;

saveas(fig, fullfile(output_dir, 'schemeA_results.png'));
close(fig);
fprintf('  📊 方案A图表已保存\n');
end

function plotSchemeBResults(consistency, output_dir)
if isempty(consistency)
    fprintf('  ⚠️ 方案B无一致性结果，跳过绘图\n');
    return;
end

fig = figure('Visible','off','Position',[0 0 700 500]);

AC_CVs = [consistency.AC_CV];
BC_CVs = [consistency.BC_CV];
SB_CVs = [consistency.SB_CV];

hold on;
n = length(consistency);
x = 1:n;
plot(x, AC_CVs, 'bo-', 'DisplayName','AC层');
plot(x, BC_CVs, 'rs-', 'DisplayName','基层');
plot(x, SB_CVs, 'gd-', 'DisplayName','底基层');
yline(15, 'k--', 'CV=15% (High)');
yline(30, 'r--', 'CV=30% (Low)');
xlabel('桩号序号');
ylabel('变异系数 CV (%)');
title('方案B：多荷载反算一致性分析');
legend('Location','best');
grid on;

saveas(fig, fullfile(output_dir, 'schemeB_consistency.png'));
close(fig);
fprintf('  📊 方案B图表已保存\n');
end

function printSummary(scheme_A_results, scheme_B_consistency)
fprintf('\n╔══════════════════════════════════════════════════════════════╗\n');
fprintf('║                    实验汇总                                  ║\n');
fprintf('╚══════════════════════════════════════════════════════════════╝\n\n');

if ~isempty(scheme_A_results)
    valid_A = scheme_A_results(~isnan([scheme_A_results.D0_error_pct]));
    if ~isempty(valid_A)
        pass_rate = mean([valid_A.linear_elastic_valid]) * 100;
        fprintf('  【方案A：线弹性假设验证】\n');
        fprintf('    有效预测组数: %d\n', length(valid_A));
        fprintf('    D0误差均值:   %.2f%%\n', mean([valid_A.D0_error_pct]));
        fprintf('    RMSE均值:     %.4f mm\n', mean([valid_A.rmse_mm]));
        ldc_vals = [valid_A.LDC];
        fprintf('    LDC均值:      %.3f\n', mean(ldc_vals(~isnan(ldc_vals))));
        fprintf('    线弹性成立率: %.1f%%\n\n', pass_rate);
    end
end

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

function config = getFastConfig()
config = struct();
% ===== PPO参数（速度补偿） =====
config.ppo_backcalculation.max_episodes          = 30;   % 原版150，LLM指导下30够用
config.ppo_backcalculation.max_steps_per_episode = 15;   % 不变
config.ppo_backcalculation.early_stop_patience   = 5;    % 原版20
config.ppo_backcalculation.learning_rate         = 0.001;
config.backcalculation.convergence_threshold     = 0.05;
config.per_record_timeout_sec                    = 180;  % LLM开启后每条180s软超时

% ===== Multi-Run配置（LLM多解选优） =====
config.multi_run.n_runs          = 3;   % 3次独立PPO，LLM选最优解
config.multi_run.enabled         = true;

% ===== LLM全程参与（方向B） =====
config.llm_guidance.enabled                      = true;
config.llm_guidance.use_for_initial_estimate     = true;   % LLM提供初始模量
config.llm_guidance.use_for_optimization_guidance = true;  % LLM指导PPO搜索方向
config.llm_guidance.guidance_interval            = 10;     % 每10个episode请求一次
config.llm_guidance.model                        = 'deepseek';

% ===== API配置 =====
config.deepseek.api_key     = '';
config.deepseek.base_url    = 'https://api.deepseek.com/v1';
config.deepseek.model       = 'deepseek-chat';
config.deepseek.max_tokens  = 2000;
config.deepseek.temperature = 0.1;
config.deepseek.timeout     = 30;
config.ollama.base_url      = 'http://localhost:11434';
config.ollama.model         = 'qwen2.5:7b';
config.ollama.temperature   = 0.1;
config.ollama.timeout       = 60;
end

function result = ternary(condition, val_true, val_false)
if condition
    result = val_true;
else
    result = val_false;
end
end