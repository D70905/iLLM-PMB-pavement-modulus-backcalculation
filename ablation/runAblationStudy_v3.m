%% runAblationStudy_v3.m - 消融实验脚本（v3.0 完整6变体）
%
% 【变体设计：2×2因子结构】
%
%              | 有物理约束(Table1 D0自适应) | 无物理约束([10,50000] MPa)
%   -----------|---------------------------|---------------------------
%   有LLM      | V1: LLM-PPO (Full)        | V5: LLM-PPO-NoConstraint
%   无LLM      | V4: PPO-Constraint        | V6: Pure PPO
%
%   V2 (w/o LLM-Guide)、V3 (w/o LLM-Init) 在有约束空间内分解LLM组件贡献
%
% 【对比关系】
%   V4 vs V6  → 物理约束对纯PPO的独立贡献（LLM=无）
%   V1 vs V5  → 物理约束对LLM-PPO的贡献（LLM=有）
%   V5 vs V6  → LLM在无约束空间的独立贡献
%   V1 vs V4  → LLM整体贡献（核心对比）
%
% 【用法】（必须显式指定变体编号）
%   runAblationStudy_v3([5,6])        % 只跑V5和V6（新增变体）
%   runAblationStudy_v3([1,2,3,4])    % 只跑原有4个变体
%   runAblationStudy_v3(1:6)          % 全部6个变体
%   runAblationStudy_v3([5,6], 'AblationResults_Temp_20260310_120000.mat')
%                                     % 断点续跑V5和V6
%
% 版本: v3.0
% 日期: 2026-03

function results = runAblationStudy_v3(variants_to_run, resume_file)

%% ═══════════════════════════════════════════════════════════════════════
%  参数检查
%% ═══════════════════════════════════════════════════════════════════════

if nargin < 1 || isempty(variants_to_run)
    error(['请显式指定要运行的变体编号，例如:\n' ...
           '  runAblationStudy_v3([5,6])     %% 只跑V5和V6\n' ...
           '  runAblationStudy_v3(1:6)       %% 全部6个变体\n' ...
           '  runAblationStudy_v3([1,2,3,4]) %% 原有4个变体']);
end

if any(~ismember(variants_to_run, 1:9))
    error('变体编号必须在1到9之间，当前输入: %s', mat2str(variants_to_run));
end

if nargin < 2
    resume_file = '';
end
resume_mode = ~isempty(resume_file) && exist(resume_file, 'file');

fprintf('\n');
fprintf('╔════════════════════════════════════════════════════════════╗\n');
fprintf('║   消融实验脚本 v3.0  (2x2因子设计，共6变体)               ║\n');
fprintf('╠════════════════════════════════════════════════════════════╣\n');
fprintf('║  本次运行变体: %-43s║\n', mat2str(variants_to_run));
if resume_mode
    fprintf('║  模式: 断点续跑                                            ║\n');
else
    fprintf('║  模式: 全新运行                                            ║\n');
end
fprintf('╚════════════════════════════════════════════════════════════╝\n\n');

%% ═══════════════════════════════════════════════════════════════════════
%  0. 断点恢复
%% ═══════════════════════════════════════════════════════════════════════

if resume_mode
    fprintf('【恢复模式】从临时文件继续: %s\n', resume_file);
    load(resume_file, 'results');
    fprintf('  已完成运行数: %d\n\n', length(results.runs));
end

%% ═══════════════════════════════════════════════════════════════════════
%  1. 加载测试案例
%% ═══════════════════════════════════════════════════════════════════════

fprintf('【步骤1】加载测试案例...\n');

if ~resume_mode
    if ~exist('loadTestCases', 'file')
        error('找不到 loadTestCases 函数，请确保在项目根目录运行。');
    end
    test_cases = loadTestCases();
    selected_cases = {'ABAQUS_1', 'ABAQUS_2', 'ABAQUS_4', 'ABAQUS_5', 'ABAQUS_7', 'ABAQUS_13'};
    for i = 1:length(selected_cases)
        if ~isfield(test_cases, selected_cases{i})
            error('案例 %s 不存在于 loadTestCases() 中。', selected_cases{i});
        end
    end
    fprintf('  选定案例: %s\n', strjoin(selected_cases, ', '));
else
    test_cases     = loadTestCases();
    selected_cases = results.metadata.selected_cases;
    fprintf('  案例信息已从文件恢复\n');
end

%% ═══════════════════════════════════════════════════════════════════════
%  2. 定义全部6个变体
%% ═══════════════════════════════════════════════════════════════════════

fprintf('\n【步骤2】定义变体配置...\n');

% 每次运行都重建完整的6变体定义，保证一致性。
%
% 字段说明：
%   name          - 内部标识符（用于文件名和字段名，不含特殊字符）
%   display_name  - 论文中显示的名称
%   llm_enabled   - LLM总开关
%   llm_init      - 是否用LLM做初始模量估计
%   llm_guide     - 是否用LLM做PPO优化引导
%   init_method   - 初始模量方法：'llm' 或 'empirical'
%   no_constraint - false = Table1 D0自适应约束（原有逻辑）
%                   true  = 无物理约束，[10,50000] MPa 均匀搜索空间

all_variants(1).name          = 'V1_Full';
all_variants(1).display_name  = 'LLM-PPO (Full)';
all_variants(1).llm_enabled   = true;
all_variants(1).llm_init      = true;
all_variants(1).llm_guide     = true;
all_variants(1).init_method   = 'llm';
all_variants(1).no_constraint = false;
all_variants(1).llm_select    = true;   % LLM-Select开启（Multi-Run + LLM评分选优）
all_variants(1).use_explicit_knowledge = false;  % V1用旧无出处prompt（保持与改造前可比）

all_variants(2).name          = 'V2_wo_Guide';
all_variants(2).display_name  = 'w/o LLM-Guide';
all_variants(2).llm_enabled   = true;
all_variants(2).llm_init      = true;
all_variants(2).llm_guide     = false;
all_variants(2).init_method   = 'llm';
all_variants(2).no_constraint = false;
all_variants(2).llm_select    = true;
all_variants(2).use_explicit_knowledge = false;

all_variants(3).name          = 'V3_wo_Init';
all_variants(3).display_name  = 'w/o LLM-Init';
all_variants(3).llm_enabled   = true;
all_variants(3).llm_init      = false;
all_variants(3).llm_guide     = true;
all_variants(3).init_method   = 'empirical';
all_variants(3).no_constraint = false;
all_variants(3).llm_select    = true;
all_variants(3).use_explicit_knowledge = false;

all_variants(4).name          = 'V4_PPO_Constraint';
all_variants(4).display_name  = 'PPO-Constraint';
all_variants(4).llm_enabled   = false;
all_variants(4).llm_init      = false;
all_variants(4).llm_guide     = false;
all_variants(4).init_method   = 'empirical';
all_variants(4).no_constraint = false;
all_variants(4).llm_select    = false;
all_variants(4).use_explicit_knowledge = false;  % 无LLM选解，字段无作用但保持结构一致

% V5: 有LLM + 无物理约束
%   与V1对比 → 物理约束对LLM-PPO的贡献
%   与V6对比 → LLM在无约束空间的独立贡献
all_variants(5).name          = 'V5_LLM_NoConst';
all_variants(5).display_name  = 'LLM-PPO-NoConstraint';
all_variants(5).llm_enabled   = true;
all_variants(5).llm_init      = true;
all_variants(5).llm_guide     = true;
all_variants(5).init_method   = 'llm';
all_variants(5).no_constraint = true;
all_variants(5).llm_select    = true;
all_variants(5).use_explicit_knowledge = false;

% V6: 无LLM + 无物理约束（真正的纯PPO基线）
%   与V4对比 → 物理约束对纯PPO的贡献
%   与V5对比 → LLM在无约束空间的独立贡献
all_variants(6).name          = 'V6_Pure_PPO';
all_variants(6).display_name  = 'Pure PPO';
all_variants(6).llm_enabled   = false;
all_variants(6).llm_init      = false;
all_variants(6).llm_guide     = false;
all_variants(6).init_method   = 'empirical';
all_variants(6).no_constraint = true;
all_variants(6).llm_select    = false;
all_variants(6).use_explicit_knowledge = false;  % 无LLM，字段无作用

% V7: 有LLM(Init+Guide) + 无LLM-Select + 有物理约束
%   LLM三个机制：A=LLM-Init，B=LLM-Guide，C=LLM-Select(Multi-Run评分)
%   V1(A+B+C) vs V7(A+B)   → 隔离LLM评分选优机制(C)的独立贡献
%   V7(A+B)   vs V4(无LLM) → A+B联合贡献（排除C后的LLM贡献）
%   Multi-Run仍执行N次，但候选解用最小D0误差选优，不调用LLM评分
all_variants(7).name          = 'V7_wo_Select';
all_variants(7).display_name  = 'w/o LLM-Select';
all_variants(7).llm_enabled   = true;
all_variants(7).llm_init      = true;
all_variants(7).llm_guide     = true;
all_variants(7).init_method   = 'llm';
all_variants(7).no_constraint = false;
all_variants(7).llm_select    = false;   % ← 关键：禁用LLM评分，改用最小D0选优
all_variants(7).use_explicit_knowledge = false;  % 无LLM选解，字段无作用

% V8: 完整三层知识架构（新增——投AEI的核心变体）
%   llm_select=true + use_explicit_knowledge=true + RAG开 + 硬约束
%   V8 vs V9 → 单独隔离"显式知识库/RAG"的贡献
all_variants(8).name          = 'V8_ExplicitKnowledge';
all_variants(8).display_name  = 'LLM-PPO + Explicit Knowledge';
all_variants(8).llm_enabled   = true;
all_variants(8).llm_init      = true;
all_variants(8).llm_guide     = true;
all_variants(8).init_method   = 'llm';
all_variants(8).no_constraint = false;
all_variants(8).llm_select    = true;
all_variants(8).use_explicit_knowledge = true;   % ← 三层知识 prompt + RAG

% V9: LLM选解但无显式知识（对照——隔离知识层贡献）
%   llm_select=true + use_explicit_knowledge=false → 旧硬编码prompt
%   V8 vs V9 → 唯一差异是知识层，其他开关完全相同
all_variants(9).name          = 'V9_NoExplicitKnowledge';
all_variants(9).display_name  = 'LLM-PPO w/o Explicit Knowledge';
all_variants(9).llm_enabled   = true;
all_variants(9).llm_init      = true;
all_variants(9).llm_guide     = true;
all_variants(9).init_method   = 'llm';
all_variants(9).no_constraint = false;
all_variants(9).llm_select    = true;
all_variants(9).use_explicit_knowledge = false;  % ← 旧硬编码 prompt，无 RAG

% 按指定编号筛选本次运行的变体
variants = all_variants(variants_to_run);

fprintf('  %-4s  %-25s  %-9s  %-9s  %-9s  %-9s\n', 'ID', '名称', 'LLM-Init', 'LLM-Guide', 'LLM-Sel', '无约束');
fprintf('  %s\n', repmat('-', 1, 75));
for i = 1:length(variants)
    fprintf('  V%-3d  %-25s  %-9s  %-9s  %-9s  %-9s\n', ...
        variants_to_run(i), variants(i).display_name, ...
        yn(variants(i).llm_init), yn(variants(i).llm_guide), ...
        yn(variants(i).llm_select), yn(variants(i).no_constraint));
end

%% ═══════════════════════════════════════════════════════════════════════
%  3. 加载基础配置
%% ═══════════════════════════════════════════════════════════════════════

fprintf('\n【步骤3】加载配置...\n');
try
    base_config = loadConfig();
    fprintf('  PPO最大Episodes: %d\n', base_config.ppo_backcalculation.max_episodes);
    fprintf('  收敛阈值: %.1f%%\n', base_config.backcalculation.convergence_threshold * 100);
catch ME
    error('配置加载失败: %s\n请确保 config_backcalculation.json 存在。', ME.message);
end

%% ═══════════════════════════════════════════════════════════════════════
%  4. 验证依赖函数
%% ═══════════════════════════════════════════════════════════════════════

if ~resume_mode
    fprintf('\n【步骤4】验证依赖函数...\n');
    required_functions = {'BackcalculationPPO', 'initialModulusGenerator', ...
                          'roadPDEModelingABAQUSCalibrated'};
    missing = {};
    for i = 1:length(required_functions)
        if ~exist(required_functions{i}, 'file')
            missing{end+1} = required_functions{i};
        end
    end
    if ~isempty(missing)
        error('缺少必要函数: %s', strjoin(missing, ', '));
    end
    fprintf('  所有依赖函数验证通过\n');
else
    fprintf('【步骤4】断点续跑，跳过依赖检查\n');
end

%% ═══════════════════════════════════════════════════════════════════════
%  5. 初始化结果存储
%% ═══════════════════════════════════════════════════════════════════════

if ~resume_mode
    fprintf('\n【步骤5】初始化结果存储...\n');
    results = struct();
    results.metadata.timestamp         = datestr(now, 'yyyymmdd_HHMMSS');
    results.metadata.selected_cases    = selected_cases;
    results.metadata.num_cases         = length(selected_cases);
    results.metadata.variants_to_run   = variants_to_run;
    results.metadata.num_runs_per_case = 3;
    results.metadata.total_runs        = length(selected_cases) * length(variants) * 3;
    results.metadata.start_time        = now;
    results.runs = [];
    fprintf('  预计: %d案例 × %d变体 × 3次 = %d 次运行\n', ...
        length(selected_cases), length(variants), results.metadata.total_runs);
    run_counter       = 0;
    global_start_time = tic;
else
    fprintf('\n【步骤5】恢复结果存储...\n');
    % 补全旧结果中可能缺失的字段，保证结构一致
    if ~isempty(results.runs)
        template  = createEmptyResult();
        tmpl_flds = fieldnames(template);
        n_patched = 0;
        for i = 1:length(results.runs)
            missing_flds = setdiff(tmpl_flds, fieldnames(results.runs(i)));
            for j = 1:length(missing_flds)
                results.runs(i).(missing_flds{j}) = template.(missing_flds{j});
            end
            if ~isempty(missing_flds), n_patched = n_patched + 1; end
        end
        if n_patched > 0
            fprintf('  已补全 %d 条旧记录的缺失字段\n', n_patched);
        end
    end
    run_counter       = length(results.runs);
    global_start_time = tic;
end

%% ═══════════════════════════════════════════════════════════════════════
%  6. 主循环
%% ═══════════════════════════════════════════════════════════════════════

fprintf('\n【步骤6】开始主循环...\n\n');
total_runs = results.metadata.total_runs;

% 记录已完成的任务（断点续跑时跳过）
completed_tasks = containers.Map('KeyType', 'char', 'ValueType', 'logical');
if resume_mode
    for i = 1:length(results.runs)
        key = sprintf('%s_%s_R%d', results.runs(i).case_name, ...
                                   results.runs(i).variant_name, ...
                                   results.runs(i).run_number);
        completed_tasks(key) = true;
    end
end

for v = 1:length(variants)
    variant = variants(v);
    vid     = variants_to_run(v);

    fprintf('\n════════════════════════════════════════════════════════════\n');
    fprintf('  V%d: %s\n', vid, variant.display_name);
    fprintf('  LLM-Init:%s  LLM-Guide:%s  无约束:%s\n', ...
        yn(variant.llm_init), yn(variant.llm_guide), yn(variant.no_constraint));
    fprintf('════════════════════════════════════════════════════════════\n');

    for c = 1:length(selected_cases)
        case_name  = selected_cases{c};
        input_data = test_cases.(case_name);

        fprintf('\n  案例 %d/%d: %s  D0=%.4fmm  AC=%dcm\n', ...
            c, length(selected_cases), case_name, ...
            input_data.measured_deflection, input_data.thickness(1));

        for r = 1:3
            key = sprintf('%s_%s_R%d', case_name, variant.name, r);
            if resume_mode && isKey(completed_tasks, key)
                fprintf('    跳过已完成: %s Run#%d\n', case_name, r);
                continue;
            end

            run_counter = run_counter + 1;
            elapsed     = toc(global_start_time);
            if run_counter > 1
                remaining = elapsed / run_counter * (total_runs - run_counter);
            else
                remaining = 0;
            end

            fprintf('    ─────────────────────────────────────────────────────\n');
            fprintf('    [%d/%d  %.1f%%]  V%d x %s x Run#%d  |  已用%.1fmin  剩余%.1fmin\n', ...
                run_counter, total_runs, run_counter/total_runs*100, ...
                vid, case_name, r, elapsed/60, remaining/60);

            try
                config     = configureVariant(base_config, variant);
                run_result = runSingleExperiment(input_data, config, case_name, variant, r);
                results.runs = [results.runs; run_result];

                fprintf('    ✓  D0=%.2f%%  模量=%.2f%%  迭代=%d  时间=%.1fs\n', ...
                    run_result.D0_error*100, run_result.mean_modulus_error*100, ...
                    run_result.iterations, run_result.time);
                fprintf('       反演: [%d, %d, %d, %d] MPa\n', ...
                    round(run_result.E_AC), round(run_result.E_BC), ...
                    round(run_result.E_SB), round(run_result.E_SG));
                if ~run_result.converged
                    fprintf('    ⚠️  未收敛 (D0=%.2f%%)\n', run_result.D0_error*100);
                end

            catch ME
                fprintf('    ❌ 失败: %s\n', ME.message);
                if ~isempty(ME.stack)
                    fprintf('       %s 行%d\n', ME.stack(1).name, ME.stack(1).line);
                end
                fr = createEmptyResult();
                fr.case_name              = case_name;
                fr.variant_name           = variant.name;
                fr.variant_display_name   = variant.display_name;
                fr.run_number             = r;
                fr.success                = false;
                fr.error_message          = ME.message;
                if ~isempty(ME.stack)
                    fr.error_stack = sprintf('%s:%d', ME.stack(1).name, ME.stack(1).line);
                end
                results.runs = [results.runs; fr];
            end

            % 断点保存：每条run完成后立即保存，防止崩溃丢失进度
            tmp = sprintf('AblationResults_Temp_%s.mat', results.metadata.timestamp);
            save(tmp, 'results');
            fprintf('    断点已保存: %s (%d/%d条)\n', tmp, length(results.runs), total_runs);
        end
    end
end

%% ═══════════════════════════════════════════════════════════════════════
%  7. 统计分析
%% ═══════════════════════════════════════════════════════════════════════

fprintf('\n【步骤7】统计分析...\n');
results.metadata.end_time           = now;
results.metadata.total_elapsed_time = toc(global_start_time);
results.statistics = computeStatistics(results.runs, variants, selected_cases);
fprintf('  成功率: %.1f%% (%d/%d)\n', ...
    results.statistics.success_rate*100, ...
    results.statistics.successful_runs, ...
    results.statistics.total_runs);

%% ═══════════════════════════════════════════════════════════════════════
%  8. 输出文件
%% ═══════════════════════════════════════════════════════════════════════

fprintf('\n【步骤8】生成输出文件...\n');
ts       = results.metadata.timestamp;
mat_file = sprintf('AblationResults_%s.mat', ts);
csv_file = sprintf('AblationTable_%s.csv',   ts);
txt_file = sprintf('AblationSummary_%s.txt', ts);

save(mat_file, 'results');
generateAblationTableCSV(results, csv_file, variants);
generateSummaryText(results, txt_file, variants);
fprintf('  MAT: %s\n  CSV: %s\n  TXT: %s\n', mat_file, csv_file, txt_file);

% 清理断点文件
tmp = sprintf('AblationResults_Temp_%s.mat', ts);
if exist(tmp, 'file'), delete(tmp); end

%% ═══════════════════════════════════════════════════════════════════════
%  9. 最终摘要
%% ═══════════════════════════════════════════════════════════════════════

fprintf('\n');
fprintf('╔════════════════════════════════════════════════════════════╗\n');
fprintf('║   消融实验完成                                             ║\n');
fprintf('╠════════════════════════════════════════════════════════════╣\n');
fprintf('║  运行次数: %-3d  成功: %-3d  失败: %-3d                      ║\n', ...
    run_counter, sum([results.runs.success]), sum(~[results.runs.success]));
fprintf('║  总耗时: %.1f 小时                                         ║\n', ...
    results.metadata.total_elapsed_time / 3600);
fprintf('╚════════════════════════════════════════════════════════════╝\n\n');

fprintf('【关键结果】\n');
vnames = fieldnames(results.statistics.by_variant);
for i = 1:length(vnames)
    vn = vnames{i};
    vs = results.statistics.by_variant.(vn);
    dname = vn;
    for v = 1:length(variants)
        if strcmp(makeValidFieldName(variants(v).name), vn)
            dname = variants(v).display_name; break;
        end
    end
    fprintf('  %-25s  D0=%.2f±%.2f%%  模量=%.1f±%.1f%%  迭代=%.1f  时间=%.1fs\n', ...
        dname, vs.D0_error_mean*100, vs.D0_error_std*100, ...
        vs.modulus_error_mean*100, vs.modulus_error_std*100, ...
        vs.iterations_mean, vs.time_mean);
end

fprintf('\n加载结果: load(''%s'');\n', mat_file);
fprintf('查看表格: readtable(''%s'');\n\n', csv_file);

end

%% ═══════════════════════════════════════════════════════════════════════
%  辅助函数
%% ═══════════════════════════════════════════════════════════════════════

function s = yn(val)
% 布尔值转显示字符串
if val, s = 'Yes'; else, s = 'No'; end
end

% -------------------------------------------------------------------------
function s = ternary_str(cond, a, b)
% 三元表达式辅助函数
if cond, s = a; else, s = b; end
end

% -------------------------------------------------------------------------
function valid_name = makeValidFieldName(name)
% 将变体名称转为合法的MATLAB结构体字段名
valid_name = strrep(name, '/', '_');
valid_name = strrep(valid_name, ' ', '_');
valid_name = strrep(valid_name, '-', '_');
valid_name = strrep(valid_name, '.', '_');
if exist('matlab.lang.makeValidName', 'builtin') || exist('matlab.lang.makeValidName', 'file')
    valid_name = matlab.lang.makeValidName(valid_name);
end
end

% -------------------------------------------------------------------------
function r = createEmptyResult()
% 创建标准结果结构体，所有字段保持一致
r.case_name            = '';
r.variant_name         = '';
r.variant_display_name = '';
r.run_number           = 0;
r.success              = false;
r.E_AC                 = NaN;
r.E_BC                 = NaN;
r.E_SB                 = NaN;
r.E_SG                 = NaN;
r.True_E_AC            = NaN;
r.True_E_BC            = NaN;
r.True_E_SB            = NaN;
r.True_E_SG            = NaN;
r.D0_error             = NaN;
r.basin_mean_error     = NaN;
r.E_AC_error           = NaN;
r.E_BC_error           = NaN;
r.E_SB_error           = NaN;
r.E_SG_error           = NaN;
r.mean_modulus_error   = NaN;
r.plausibility         = NaN;   % 选解物理合理性指标（FWD等效区间）
r.plausibility_layers  = [NaN NaN NaN NaN];
r.iterations           = 0;
r.time                 = 0;
r.converged            = false;
r.llm_call_count       = 0;
r.measured_basin       = [];
r.calculated_basin     = [];
r.error_history        = [];
r.error_message        = '';
r.error_stack          = '';
end

% -------------------------------------------------------------------------
function config = configureVariant(base_config, variant)
% 根据变体定义配置LLM开关及约束空间
%
% LLM三个机制：
%   llm_init   (A): LLM初始模量估计（替代经验公式）
%   llm_guide  (B): PPO优化中按guidance_interval调用LLM给搜索方向建议
%   llm_select (C): Multi-Run N次后LLM对候选解评物理合理性(10分制)，选最优
%                   关闭时改用最小D0误差选优，Multi-Run次数不变
%
% no_constraint=false (V1-V4,V7): Table1 D0自适应约束 + 层次约束
% no_constraint=true  (V5-V6):    [10,50000] MPa 均匀空间，无任何物理约束

config = base_config;

% ── LLM Init 和 Guide ──────────────────────────────────────────────────
config.llm_guidance.enabled                       = variant.llm_enabled;
config.llm_guidance.use_for_initial_estimate      = variant.llm_init;
config.llm_guidance.use_for_optimization_guidance = variant.llm_guide;

% ── LLM Select（Multi-Run候选解选优方式） ─────────────────────────────
if isfield(variant, 'llm_select')
    config.llm_guidance.use_for_solution_selection = variant.llm_select;
    if variant.llm_select
        config.multi_run.selection_method = 'llm_scoring';   % LLM物理合理性评分
        fprintf('      [LLM-Select] 开启：Multi-Run后LLM评分选优\n');
    else
        config.multi_run.selection_method = 'min_d0_error';  % 最小D0误差选优
        fprintf('      [LLM-Select] 关闭：Multi-Run后最小D0误差选优\n');
    end
else
    config.llm_guidance.use_for_solution_selection = true;
    config.multi_run.selection_method = 'llm_scoring';
end

% ── 无约束模式 (V5/V6) ────────────────────────────────────────────────
% 【重要】BackcalculationPPO 在构造函数第151行只调用 getConstraintsByDeflection()，
%   完全不读取 config.backcalculation 里的约束字段。
%   因此必须通过 config.ablation_no_constraint = true 传入，
%   并在 runSingleExperiment 里构造 BackcalculationPPO 之后立即调用
%   ppo.modulus_constraints = ppo.getWideConstraints() 覆盖。
if isfield(variant, 'no_constraint') && variant.no_constraint
    config.ablation_no_constraint = true;
    fprintf('      [约束] 无约束模式 → 将在实验中覆盖为 getWideConstraints()\n');
else
    config.ablation_no_constraint = false;
    fprintf('      [约束] D0自适应约束 + 层次约束 (Table 1)\n');

    % ── 显式知识层开关（新增，用于V8/V9对照）────────────────────────────────
    if isfield(variant, 'use_explicit_knowledge')
        config.use_explicit_knowledge = variant.use_explicit_knowledge;
    else
        config.use_explicit_knowledge = true;   % 安全默认
    end
    if config.use_explicit_knowledge
        fprintf('      [知识层] 三层知识架构（硬约束+RAG软约束+规范出处）\n');
    else
        fprintf('      [知识层] 旧硬编码prompt（无规范出处，消融对照）\n');
    end
end
end

% -------------------------------------------------------------------------
function result = runSingleExperiment(input_data, config, case_name, variant, run_number)
% 执行单次反演实验（含Multi-Run + 选优）
%
% Multi-Run流程（与runBackcalculation.m保持一致）：
%   1. 生成基础初始模量（LLM或经验公式）
%   2. 执行N_RUNS次独立PPO（第1次用基础初始模量，后续加±35%扰动）
%   3. 选优：
%      - llm_select=true  → 调用llmSelectBestSolution（LLM物理合理性评分）
%      - llm_select=false → 直接取最小D0误差的候选解（V7专用）
%
% 注意：这里的run_number（1~3）是消融实验的重复次数，
%       与Multi-Run内部的run_idx（1~N_RUNS）是两个不同的概念。

N_RUNS             = 5;   % Multi-Run独立运行次数（与runBackcalculation保持一致）
PERTURBATION_RANGE = [0.65, 1.35];  % 初始模量扰动范围±35%

% ── 确定选优方式 ──────────────────────────────────────────────────────────
use_llm_select = true;  % 默认使用LLM评分选优
if isfield(config, 'multi_run') && isfield(config.multi_run, 'selection_method')
    use_llm_select = strcmp(config.multi_run.selection_method, 'llm_scoring');
end
if use_llm_select
    fprintf('      [选优] LLM物理合理性评分选优\n');
else
    fprintf('      [选优] 最小D0误差选优（V7模式）\n');
end

% ── 生成基础初始模量 ──────────────────────────────────────────────────────
try
    base_initial_modulus = initialModulusGenerator(input_data, config, variant.init_method);
    fprintf('      初始模量 (%s): [%d, %d, %d, %d] MPa\n', variant.init_method, ...
        round(base_initial_modulus.surface), round(base_initial_modulus.base), ...
        round(base_initial_modulus.subbase), round(base_initial_modulus.subgrade));
catch ME
    if contains(ME.message, 'LLM') || contains(ME.message, 'API')
        fprintf('      LLM初始估计失败，降级到经验公式: %s\n', ME.message);
        base_initial_modulus = empiricalInitialEstimate(input_data);
    else
        rethrow(ME);
    end
end

% 无约束变体(V5/V6)：截断到宽松范围
if isfield(config, 'ablation_no_constraint') && config.ablation_no_constraint
    WIDE_LB = 100; WIDE_UB = 50000;
    base_initial_modulus.surface  = max(WIDE_LB, min(WIDE_UB, base_initial_modulus.surface));
    base_initial_modulus.base     = max(WIDE_LB, min(WIDE_UB, base_initial_modulus.base));
    base_initial_modulus.subbase  = max(WIDE_LB, min(WIDE_UB, base_initial_modulus.subbase));
    base_initial_modulus.subgrade = max(10,      min(500,     base_initial_modulus.subgrade));
end

% ── Multi-Run主循环 ───────────────────────────────────────────────────────
all_solutions = struct();
n_converged   = 0;
t_total_start = tic;

for run_idx = 1:N_RUNS
    fprintf('\n      ── Multi-Run %d/%d ──\n', run_idx, N_RUNS);

    % 第1次用基础初始模量，后续加扰动（与runBackcalculation一致）
    if run_idx == 1
        run_initial_modulus = base_initial_modulus;
    else
        rng(run_number * 100 + run_idx);  % 可复现随机种子
        f_s = PERTURBATION_RANGE(1) + rand() * diff(PERTURBATION_RANGE);
        f_b = PERTURBATION_RANGE(1) + rand() * diff(PERTURBATION_RANGE);
        f_sb = PERTURBATION_RANGE(1) + rand() * diff(PERTURBATION_RANGE);
        run_initial_modulus = base_initial_modulus;
        run_initial_modulus.surface  = round(base_initial_modulus.surface  * f_s  / 50) * 50;
        run_initial_modulus.base     = round(base_initial_modulus.base     * f_b  / 50) * 50;
        run_initial_modulus.subbase  = round(base_initial_modulus.subbase  * f_sb / 50) * 50;
        % 无约束变体扰动边界
        if isfield(config, 'ablation_no_constraint') && config.ablation_no_constraint
            run_initial_modulus.surface  = max(100,  min(50000, run_initial_modulus.surface));
            run_initial_modulus.base     = max(100,  min(50000, run_initial_modulus.base));
            run_initial_modulus.subbase  = max(100,  min(50000, run_initial_modulus.subbase));
        else
            run_initial_modulus.surface  = max(500,  min(15000, run_initial_modulus.surface));
            run_initial_modulus.base     = max(100,  min(35000, run_initial_modulus.base));
            run_initial_modulus.subbase  = max(50,   min(8000,  run_initial_modulus.subbase));
        end
        fprintf('        扰动系数: AC=%.2f BC=%.2f SB=%.2f\n', f_s, f_b, f_sb);
    end

    % 初始PDE
    run_initial_pde = computeInitialPDE(input_data, run_initial_modulus);

    try
        % 构造PPO
        ppo = BackcalculationPPO(input_data, config, run_initial_modulus, run_initial_pde);

        % 【关键】V5/V6无约束变体：覆盖约束
        if isfield(config, 'ablation_no_constraint') && config.ablation_no_constraint
            ppo.modulus_constraints = ppo.getWideConstraints();
            fprintf('        [覆盖约束] → getWideConstraints()\n');
        end

        [run_modulus, run_log] = ppo.optimize();

        % 计算误差
        run_pde      = computeFinalPDE(input_data, run_modulus);
        run_D0_err   = abs(run_pde.D0 - input_data.measured_deflection) / ...
                       input_data.measured_deflection;
        run_basin_errs = abs(run_pde.deflections - input_data.deflection_basin) ./ ...
                         input_data.deflection_basin;
        run_basin_err  = mean(run_basin_errs) * 100;

        % 存入候选解
        n_converged = n_converged + 1;
        all_solutions(n_converged).run_idx    = run_idx;
        all_solutions(n_converged).modulus    = run_modulus;
        all_solutions(n_converged).pde_results = run_pde;
        all_solutions(n_converged).D0_error   = run_D0_err;
        all_solutions(n_converged).basin_error = run_basin_err;
        all_solutions(n_converged).converged  = run_log.converged;
        all_solutions(n_converged).opt_log    = run_log;

        fprintf('        ✓ D0误差=%.2f%%  弯沉盆=%.2f%%  收敛=%s\n', ...
            run_D0_err*100, run_basin_err, ternary_str(run_log.converged,'是','否'));

    catch ME_run
        fprintf('        ✗ 失败: %s\n', ME_run.message);
    end
end

elapsed = toc(t_total_start);
fprintf('\n      Multi-Run完成: %d/%d个候选解  总耗时%.1fs\n', n_converged, N_RUNS, elapsed);

% ── 选优 ──────────────────────────────────────────────────────────────────
if n_converged == 0
    error('所有%d次Multi-Run均失败，无法完成反演。', N_RUNS);
elseif n_converged == 1
    selected_idx = 1;
    fprintf('      仅1个候选解，直接采用。\n');
elseif use_llm_select
    % LLM物理合理性评分选优（V1/V2/V3/V5）
    selected_idx = llmSelectBestSolution(all_solutions, n_converged, input_data, config);
    fprintf('      [LLM选优] 采用第%d次运行的解\n', all_solutions(selected_idx).run_idx);
else
    % 最小D0误差选优（V7: w/o LLM-Select）
    d0_errors = arrayfun(@(s) s.D0_error, all_solutions(1:n_converged));
    [~, selected_idx] = min(d0_errors);
    fprintf('      [最小D0选优] 采用第%d次运行的解 (D0=%.2f%%)\n', ...
        all_solutions(selected_idx).run_idx, d0_errors(selected_idx)*100);
end

% ── 提取最终结果 ──────────────────────────────────────────────────────────
final_modulus = all_solutions(selected_idx).modulus;
final_pde     = all_solutions(selected_idx).pde_results;
opt_log       = all_solutions(selected_idx).opt_log;
opt_log.multi_run_n_candidates = n_converged;
opt_log.multi_run_selected_idx = selected_idx;

D0_error         = abs(final_pde.D0 - input_data.measured_deflection) / input_data.measured_deflection;
basin_errors     = abs(final_pde.deflections - input_data.deflection_basin) ./ input_data.deflection_basin;
basin_mean_error = mean(basin_errors);

if isfield(input_data, 'true_modulus')
    tm = input_data.true_modulus;
    mod_errors = [
        abs(final_modulus.surface  - tm.surface)  / tm.surface;
        abs(final_modulus.base     - tm.base)      / tm.base;
        abs(final_modulus.subbase  - tm.subbase)   / tm.subbase;
        abs(final_modulus.subgrade - tm.subgrade)  / tm.subgrade
    ];
    mean_mod_error = mean(mod_errors);
else
    mod_errors     = [NaN; NaN; NaN; NaN];
    mean_mod_error = NaN;
end

% ── 整理结果结构体 ────────────────────────────────────────────────────────
result = createEmptyResult();
result.case_name            = case_name;
result.variant_name         = variant.name;
result.variant_display_name = variant.display_name;
result.run_number           = run_number;
result.success              = true;
result.E_AC                 = final_modulus.surface;
result.E_BC                 = final_modulus.base;
result.E_SB                 = final_modulus.subbase;
result.E_SG                 = final_modulus.subgrade;
if isfield(input_data, 'true_modulus')
    result.True_E_AC = input_data.true_modulus.surface;
    result.True_E_BC = input_data.true_modulus.base;
    result.True_E_SB = input_data.true_modulus.subbase;
    result.True_E_SG = input_data.true_modulus.subgrade;
end
result.D0_error           = D0_error;
result.basin_mean_error   = basin_mean_error;
result.E_AC_error         = mod_errors(1);
result.E_BC_error         = mod_errors(2);
result.E_SB_error         = mod_errors(3);
result.E_SG_error         = mod_errors(4);
result.mean_modulus_error = mean_mod_error;

%% ── 计算选解物理合理性（FWD等效区间，独立于RAG服务——裁判中立）────
plausible_range = getPlausibleRange(input_data);
layer_names = {'surface','base','subbase','subgrade'};
play_scores = zeros(1,4);
for li = 1:4
    Ei = final_modulus.(layer_names{li});
    lo = plausible_range.(layer_names{li})(1);
    hi = plausible_range.(layer_names{li})(2);
    if Ei >= lo && Ei <= hi
        play_scores(li) = 1.0;
    elseif Ei < lo
        play_scores(li) = max(0, 1 - (lo - Ei)/lo);
    else
        play_scores(li) = max(0, 1 - (Ei - hi)/hi);
    end
end
result.plausibility = mean(play_scores);
result.plausibility_layers = play_scores;
fprintf('      合理性=%.2f (各层: AC=%.2f BC=%.2f SB=%.2f SG=%.2f)\n', ...
    result.plausibility, play_scores(1), play_scores(2), play_scores(3), play_scores(4));
result.iterations         = opt_log.iterations;
result.time               = elapsed;
result.converged          = opt_log.converged;
result.llm_call_count     = opt_log.llm_call_count;
result.measured_basin     = input_data.deflection_basin;
result.calculated_basin   = final_pde.deflections;
result.error_history      = opt_log.error_history;
end

% -------------------------------------------------------------------------
function initial_modulus = empiricalInitialEstimate(input_data)
% LLM不可用时的经验公式降级
D0 = input_data.measured_deflection;
initial_modulus.surface  = max(500,  min(8000,  3000 * exp(-2.0 * D0)));
initial_modulus.base     = max(200,  min(3000,  1000 * exp(-1.5 * D0)));
initial_modulus.subbase  = max(100,  min(1000,  400  * exp(-1.0 * D0)));
initial_modulus.subgrade = input_data.subgrade_modulus;
if ~isfield(initial_modulus, 'subgrade') || isnan(initial_modulus.subgrade)
    initial_modulus.subgrade = 50;
end
end

% -------------------------------------------------------------------------
function pde_results = computeInitialPDE(input_data, initial_modulus)
% [Fix v3.1] 外层catch已基本不会触发（callPDE内部已有完整try-catch）
% 保留作为最后防线，但确保返回字段与正常结果一致
try
    params      = buildPDEParams(input_data, initial_modulus);
    pde_results = callPDE(params, input_data);
catch
    pde_results.D0          = input_data.measured_deflection * 1.5;
    pde_results.deflections = input_data.deflection_basin * 1.5;
    pde_results.success     = false;
end
end

function pde_results = computeFinalPDE(input_data, final_modulus)
% [Fix v3.1] 同上
try
    params      = buildPDEParams(input_data, final_modulus);
    pde_results = callPDE(params, input_data);
catch
    pde_results.D0          = input_data.measured_deflection * 1.5;
    pde_results.deflections = input_data.deflection_basin * 1.5;
    pde_results.success     = false;
end
end

function params = buildPDEParams(input_data, modulus)
params.moduli    = [modulus.surface; modulus.base; modulus.subbase; modulus.subgrade];
params.thickness = input_data.thickness;
params.poisson   = input_data.poisson;
params.load_p    = input_data.load_pressure;
params.load_r    = input_data.load_radius;
params.offsets   = input_data.sensor_offsets;
end

function result = callPDE(params, input_data)
% [Fix v3.1] 使用3-struct接口，与roadPDEModelingABAQUSCalibrated v5.7.2保持一致
% 原6参数调用方式已废弃，会导致PDE异常、进入fallback(×1.5)、D0误差恒为50%

designParams = struct();
designParams.thickness = params.thickness(:);
designParams.modulus   = params.moduli(1:3);   % [E_AC; E_BC; E_SB]，不含土基
designParams.poisson   = params.poisson(:);

loadParams = struct();
loadParams.load_pressure = params.load_p;
loadParams.load_radius   = params.load_r;

boundary_conditions = struct();
boundary_conditions.modeling_type    = 'multilayer_subgrade';
boundary_conditions.subgrade_modulus = params.moduli(4);  % E_SG
boundary_conditions.soil_modulus     = params.moduli(4);
boundary_conditions.sensor_offsets   = params.offsets;

% 传递路面类型（半刚性/柔性），确保校准因子正确选择
if isfield(input_data, 'pavement_type')
    boundary_conditions.pavement_type = input_data.pavement_type;
end

try
    pde_out = roadPDEModelingABAQUSCalibrated(designParams, loadParams, boundary_conditions);
    if isfield(pde_out, 'success') && ~pde_out.success
        error('roadPDEModelingABAQUSCalibrated returned success=false');
    end
    if isfield(pde_out, 'D0')
        result.D0 = pde_out.D0;
    else
        result.D0 = pde_out.deflections(1);
    end
    result.deflections = pde_out.deflections;
    result.success     = true;
catch ME
    % fallback仅用于极端异常；记录原因便于排查
    warning('callPDE:PDEFailed', 'PDE计算失败，使用fallback(×1.5): %s', ME.message);
    result.D0          = input_data.measured_deflection * 1.5;
    result.deflections = input_data.deflection_basin * 1.5;
    result.success     = false;
end
end

% -------------------------------------------------------------------------

%% -------------------------------------------------------------------------
function r = getPlausibleRange(input_data)
%% FWD现场反算等效模量典型区间 [lo,hi] (MPa)
%% 数值来源：JTG D50 表5.5.11/5.4.5/5.3.8/5.2.2
%%          经§5.4.6室内→FWD换算(x0.5)
%% 注意：此区间独立于RAG检索服务，作为"中立裁判"

%% 判断路面类型
if isfield(input_data, 'pavement_type_name')
    ptype = input_data.pavement_type_name;
elseif isfield(input_data, 'pavement_type')
    ptype = input_data.pavement_type;
else
    ptype = 'semi_rigid';
end
is_semi = contains(lower(ptype), 'semi') || contains(ptype, '半刚性') || contains(ptype, '无机结合料');

if is_semi
    %% 半刚性路面 FWD等效区间
    %% AC面层: JTG D50表5.5.11 20°C动态模量(7000~13500), FWD现场值视温度而定
    %%   常温: 1500~4000; 低温取高值 3000~6000; 高温取低值 800~2000
    r.surface  = [800, 6000];    %% AC面层 FWD等效 (覆盖常/低/高温)
    %% 水泥稳定碎石基层: JTG D50表5.4.5 室内18000~28000 x0.5 = 9000~14000
    r.base     = [1000, 14000];  %% 水泥稳定碎石基层 FWD等效
    %% 底基层(水泥稳定类或粒料): 取宽区间
    r.subbase  = [150, 7000];    %% 底基层 FWD等效 (粒料190~440至半刚性1000~7000)
    %% 土基: JTG D50表5.2.2
    r.subgrade = [20, 200];      %% 土基 FWD等效
else
    %% 柔性路面 FWD等效区间
    r.surface  = [800, 6000];    %% AC面层 同上
    %% 粒料基层: JTG D50表5.3.8 湿度调整后 300~700
    r.base     = [150, 700];     %% 粒料基层 FWD等效
    %% 粒料底基层: JTG D50表5.3.8 湿度调整后 190~440
    r.subbase  = [130, 440];     %% 粒料底基层 FWD等效
    r.subgrade = [20, 200];      %% 土基 FWD等效
end
end
function stats = computeStatistics(runs, variants, selected_cases)
stats.total_runs      = length(runs);
stats.successful_runs = sum([runs.success]);
stats.success_rate    = stats.successful_runs / stats.total_runs;
stats.by_variant      = struct();
stats.by_case         = struct();

for v = 1:length(variants)
    vfn   = makeValidFieldName(variants(v).name);
    vmask = strcmp({runs.variant_name}, variants(v).name) & [runs.success];
    vruns = runs(vmask);
    ntot  = sum(strcmp({runs.variant_name}, variants(v).name));
    if isempty(vruns)
        vs.n_total          = ntot;
        vs.n_converged      = 0;
        vs.convergence_rate = 0;
        vs.D0_error_mean    = NaN; vs.D0_error_std    = NaN;
        vs.modulus_error_mean = NaN; vs.modulus_error_std = NaN;
        vs.plausibility_mean = NaN; vs.plausibility_std  = NaN;
        vs.iterations_mean  = NaN; vs.time_mean        = NaN;
    else
        vs.n_total          = ntot;
        vs.n_converged      = sum([vruns.converged]);
        vs.convergence_rate = vs.n_converged / ntot;
        vs.D0_error_mean    = mean([vruns.D0_error]);
        vs.D0_error_std     = std([vruns.D0_error]);
        vs.modulus_error_mean = nanmean([vruns.mean_modulus_error]);
        vs.modulus_error_std  = nanstd([vruns.mean_modulus_error]);
        vs.plausibility_mean = nanmean([vruns.plausibility]);
        vs.plausibility_std  = nanstd([vruns.plausibility]);
        vs.iterations_mean  = mean([vruns.iterations]);
        vs.time_mean        = mean([vruns.time]);
    end
    stats.by_variant.(vfn) = vs;
end

for c = 1:length(selected_cases)
    cn    = selected_cases{c};
    cfn   = makeValidFieldName(cn);
    cmask = strcmp({runs.case_name}, cn) & [runs.success];
    cruns = runs(cmask);
    if isempty(cruns)
        stats.by_case.(cfn) = struct('n_runs', 0, 'n_converged', 0, ...
            'convergence_rate', 0, 'D0_error_mean', NaN);
    else
        cs.n_runs           = length(cruns);
        cs.n_converged      = sum([cruns.converged]);
        cs.convergence_rate = cs.n_converged / cs.n_runs;
        cs.D0_error_mean    = mean([cruns.D0_error]);
        stats.by_case.(cfn) = cs;
    end
end
end

% -------------------------------------------------------------------------
function generateAblationTableCSV(results, filename, variants)
rows = {};
for v = 1:length(variants)
    vmask = strcmp({results.runs.variant_name}, variants(v).name);
    vruns = results.runs(vmask);
    for i = 1:length(vruns)
        r = vruns(i);
        rows{end+1} = {r.variant_display_name, r.case_name, r.run_number, ...
            r.converged, r.D0_error*100, r.mean_modulus_error*100, ...
            r.iterations, r.time, r.E_AC, r.E_BC, r.E_SB, r.E_SG};
    end
end
if isempty(rows), return; end
T = cell2table(vertcat(rows{:}), 'VariableNames', ...
    {'Variant','Case','Run','Converged','D0_Error_pct','Modulus_Error_pct', ...
     'Iterations','Time_s','E_AC_MPa','E_BC_MPa','E_SB_MPa','E_SG_MPa'});
writetable(T, filename);
end

% -------------------------------------------------------------------------
function generateSummaryText(results, filename, variants)
fid = fopen(filename, 'w');
fprintf(fid, 'Ablation Study Summary\n');
fprintf(fid, 'Generated: %s\n\n', datestr(now));
fprintf(fid, '%-25s  %-10s  %-16s  %-16s\n', ...
    'Variant', 'Conv.Rate', 'D0 Error (%)', 'Mod.Error (%)');
fprintf(fid, '%s\n', repmat('-', 1, 72));
for v = 1:length(variants)
    vfn = makeValidFieldName(variants(v).name);
    if ~isfield(results.statistics.by_variant, vfn), continue; end
    vs = results.statistics.by_variant.(vfn);
    fprintf(fid, '%-25s  %-10s  %-16s  %-16s\n', ...
        variants(v).display_name, ...
        sprintf('%.1f%%', vs.convergence_rate*100), ...
        sprintf('%.2f+/-%.2f', vs.D0_error_mean*100, vs.D0_error_std*100), ...
        sprintf('%.1f+/-%.1f',  vs.modulus_error_mean*100, vs.modulus_error_std*100));
end
fclose(fid);
end

% -------------------------------------------------------------------------
function config = loadConfig()
config_file = 'config_backcalculation.json';
if exist(config_file, 'file')
    try
        config = validateConfigFields(jsondecode(fileread(config_file)));
        return;
    catch
    end
end
config = getDefaultConfig();
end

function config = validateConfigFields(config)
default = getDefaultConfig();
flds    = fieldnames(default);
for i = 1:length(flds)
    if ~isfield(config, flds{i})
        config.(flds{i}) = default.(flds{i});
    end
end
% 【消融实验专用】强制覆盖，防止JSON中的值干扰消融实验设置
config.ppo_backcalculation.max_episodes = 15;
end

function config = getDefaultConfig()
config.ppo_backcalculation.max_episodes         = 15;
config.ppo_backcalculation.early_stop_patience  = 20;
config.backcalculation.convergence_threshold    = 0.03;
config.backcalculation.use_adaptive_bounds      = true;
config.backcalculation.enforce_layer_hierarchy  = true;
config.llm_guidance.enabled                     = false;
config.llm_guidance.use_for_initial_estimate    = false;
config.llm_guidance.use_for_optimization_guidance = false;
config.llm_guidance.model                       = 'deepseek-chat';
config.llm_guidance.guidance_interval           = 10;
config.deepseek.api_key                         = '';
config.deepseek.model                           = 'deepseek-chat';
% Multi-Run配置（与runBackcalculation.m保持一致）
config.multi_run.num_runs                       = 5;
config.multi_run.selection_method               = 'llm_scoring';  % 'llm_scoring' | 'min_d0_error'
end