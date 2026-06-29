function selected_idx = llmSelectBestSolution(all_solutions, n_solutions, input_data, config)
% LLMSELECTBESTSOLUTION  调用LLM对多个候选反演解进行物理合理性评分，返回最优解索引
%
% 输入:
%   all_solutions  - 候选解结构体数组（来自Multi-Run）
%   n_solutions    - 有效候选解数量
%   input_data     - 原始输入数据（含路面类型、层厚、荷载等）
%   config         - 系统配置（含LLM API参数）
%
% 输出:
%   selected_idx   - 在 all_solutions 中被选中解的索引
%
% 版本: v1.0 (Multi-Run LLM Selection)
% 对应论文章节: "Solution Selection via LLM Physical Reasoning"

fprintf('\n  ┌──────────────────────────────────────────────────────────┐\n');
fprintf('  │          LLM 物理推理评分选优模块                        │\n');
fprintf('  └──────────────────────────────────────────────────────────┘\n');

% ===== 0. 统一 all_solutions 类型：cell数组 → struct数组 =====
% 兼容两种调用方式：
%   正式流程: all_solutions 是 struct array (runAblationStudy_v3 的 Multi-Run 循环赋值)
%   测试脚本: all_solutions 可能是 cell array {sol1, sol2, ...}
if iscell(all_solutions)
    sol_array = struct('run_idx',{}, 'modulus',{}, 'pde_results',{}, ...
                       'D0_error',{}, 'basin_error',{}, 'converged',{}, 'opt_log',{});
    for ci = 1:n_solutions
        s = all_solutions{ci};
        fn = fieldnames(s);
        for fi = 1:length(fn)
            sol_array(ci).(fn{fi}) = s.(fn{fi});
        end
    end
    all_solutions = sol_array;
end

% ===== 1. 构建候选解摘要（供提示词使用）=====
solutions_summary = buildSolutionsSummary(all_solutions, n_solutions, input_data);

% ===== 2. 构建LLM评分提示词 =====
% 检查知识层开关（默认开启，兼容旧调用）
if isfield(config, 'use_explicit_knowledge')
    use_exp = config.use_explicit_knowledge;
else
    use_exp = true;
end
prompt = buildScoringPrompt(solutions_summary, input_data, n_solutions, use_exp);

fprintf('  正在调用LLM进行物理推理评分（模型: %s）...\n', config.llm_guidance.model);

% ===== 3. 调用LLM =====
response = callLLMAPI(prompt, config, config.llm_guidance.model);

if isempty(response)
    fprintf('  ⚠️ LLM调用失败，退回到最小D0误差策略\n');
    selected_idx = fallbackByMinError(all_solutions, n_solutions);
    return;
end

fprintf('  LLM响应已收到（%d字符）\n', length(response));

% ===== 4. 解析LLM评分结果 =====
[selected_idx, scores, citations] = parseLLMScores(response, n_solutions);

if selected_idx < 1 || selected_idx > n_solutions
    fprintf('  ⚠️ LLM评分解析失败，退回到最小D0误差策略\n');
    selected_idx = fallbackByMinError(all_solutions, n_solutions);
    return;
end

% ===== 5. 打印评分结果 =====
fprintf('\n  ┌────┬──────────┬──────────┬────────────┬────────┬───────────────┐\n');
fprintf('  │Run │ AC(MPa)  │ BC(MPa)  │  SB(MPa)  │D0误差  │  LLM评分     │\n');
fprintf('  ├────┼──────────┼──────────┼────────────┼────────┼───────────────┤\n');
for i = 1:n_solutions
    marker = '  ';
    if i == selected_idx, marker = '>>'; end
    fprintf('  │%s%d │  %6d  │  %6d  │   %5d   │ %5.2f%% │    %.1f/10     │\n', ...
        marker, all_solutions(i).run_idx, ...
        round(all_solutions(i).modulus.surface), ...
        round(all_solutions(i).modulus.base), ...
        round(all_solutions(i).modulus.subbase), ...
        all_solutions(i).D0_error * 100, ...
        scores(i));
end
fprintf('  └────┴──────────┴──────────┴────────────┴────────┴───────────────┘\n');
fprintf('  >> 已选择：第 %d 次运行的解（LLM评分最高: %.1f/10）\n\n', ...
    all_solutions(selected_idx).run_idx, scores(selected_idx));

% ===== 6. 保存评分日志 =====
saveScoringLog(all_solutions, n_solutions, scores, selected_idx, response, citations, input_data);

end

%% ==================== 子函数：构建候选解摘要 ====================
function summary = buildSolutionsSummary(all_solutions, n_solutions, input_data)
% 将所有候选解格式化为结构化文字，嵌入提示词

summary = '';
for i = 1:n_solutions
    sol = all_solutions(i);
    m   = sol.modulus;
    
    % 弯沉盆误差分布（若有）
    if isfield(sol.pde_results, 'deflections') && ...
       length(sol.pde_results.deflections) >= length(input_data.deflection_basin)
        n_s = length(input_data.deflection_basin);
        calc_d  = sol.pde_results.deflections(1:n_s);
        meas_d  = input_data.deflection_basin(1:n_s);
        err_pct = abs(calc_d - meas_d) ./ meas_d * 100;
        basin_str = sprintf('%.1f%% ', err_pct);
    else
        basin_str = 'N/A';
    end
    
   summary = [summary, sprintf(...
        '候选解%d: AC=%d MPa, BC=%d MPa, SB=%d MPa, SG=%d MPa\n  D0误差=%.2f%%, 弯沉盆各点误差=[%s]\n', ...
        i, round(m.surface), round(m.base), round(m.subbase), ...
        round(m.subgrade), sol.D0_error*100, basin_str)];
end
end

%% ==================== 子函数：构建LLM评分提示词 ====================
function prompt = buildScoringPrompt(solutions_summary, input_data, n_solutions, use_explicit_knowledge)
% 【核心】LLM评分提示词设计
%
% 参数:
%   use_explicit_knowledge (bool) - true=三层知识架构(硬约束+RAG软约束+带出处)
%                                    false=旧硬编码prompt(无规范出处，用于消融对照)
%
% 对应论文章节: "三层知识引导的反演解选择"

if nargin < 4
    use_explicit_knowledge = true;   % 默认三层知识模式
end

% 路面类型描述
if isfield(input_data, 'pavement_type_name')
    pavement_desc = input_data.pavement_type_name;
elseif isfield(input_data, 'pavement_type')
    pavement_desc = input_data.pavement_type;
else
    pavement_desc = 'semi_rigid';
end
if isfield(input_data, 'temperature')
    temp_desc = sprintf('%.1f°C', input_data.temperature);
    temp_val = input_data.temperature;
else
    temp_desc = '未知';
    temp_val = 20;
end

% 层厚描述
thickness_str = sprintf('%.1f cm', input_data.thickness(1));
for k = 2:length(input_data.thickness)
    thickness_str = [thickness_str, sprintf(', %.1f cm', input_data.thickness(k))];
end

% 荷载描述
load_kN = input_data.load_pressure * pi * (input_data.load_radius/100)^2 * 1000;

% ===== 分支：无显式知识模式 → 返回旧硬编码 prompt（V9 及消融对照用）=====
if ~use_explicit_knowledge
    prompt = buildOldHardcodedPrompt(solutions_summary, input_data, n_solutions, ...
        pavement_desc, thickness_str, load_kN, temp_desc);
    return;
end

% ===== 第一层：硬约束层（静态注入，普适不可逾越的物理边界）=====
% 所有知识均标注规范出处，满足 AEI "explicit representation of knowledge" 要求
hard_constraints = sprintf([...
'【不可逾越的物理边界——依据现行规范】\n' ...
'1. 层间模量梯度规则（JTG D50-2017 第4章 结构组合设计）：\n' ...
'   - 沥青路面（柔性基层）：面层 > 基层 > 底基层 > 土基，从上到下递减\n' ...
'   - 半刚性路面（无机结合料稳定类基层）：水泥稳定碎石基层模量可高于沥青面层（即基层 > 面层常见且合理）\n' ...
'   - 土基模量不得高于其上任何结构层，路基是弹性层状体系中最软的一层\n' ...
'2. 泊松比参照值（JTG D50-2017 表5.6.1）：\n' ...
'   - 密级配沥青混合料 0.25，无机结合料稳定类 0.25，粒料 0.35，路基 0.40\n' ...
'3. 弹性模量FWD-Lab转换（JTG D50-2017 第5.4.6条）：\n' ...
'   - 无机结合料稳定类：室内弹性模量 ≈ 2 × FWD反算模量，即反算值约为室内值的50%%\n' ...
'   - 需注意这一系统性差异，FWD反算值显著低于室内试验值属于正常现象\n']);

% ===== 第二层：RAG软约束层（动态检索，按路面类型+材料+温度匹配规范知识）=====
% 构建查询：路面类型 + 材料 + 温度 + 层厚
rag_query = buildRAGQuery(pavement_desc, input_data, temp_val);
rag_knowledge = callRAGService(rag_query, 4);

% 若RAG检索失败，回退到内置出处的静态知识
if isempty(rag_knowledge) || length(rag_knowledge) < 20
    rag_knowledge = buildFallbackKnowledge(pavement_desc, temp_val);
end

rag_section = sprintf([...
'【针对本算例检索到的规范依据——作为物理合理性软引导】\n' ...
'以下知识来自规范检索系统，每条标注了规范出处。重要提醒：\n' ...
'  - JTG D50 表5.4.5 的弹性模量为室内试验值（水泥稳定粒料 18000~28000 MPa）\n' ...
'  - FWD现场反算模量约为室内值的50%%（依据JTG D50 §5.4.6: 室内≈2×FWD反算）\n' ...
'  - 因此评分时，FWD反算值应对照\"FWD等效范围\"判断，而非直接对照室内值\n' ...
'LLM应据此判断候选解的工程合理性，偏离规范典型值较大时应在维度1中酌情扣分\n' ...
'（软约束：引导而非强制排除）：\n\n%s\n'], ...
    rag_knowledge);

% ===== 构建完整提示词 =====
prompt = sprintf([...
'你是一位路面结构工程专家，精通沥青路面和半刚性路面的力学特性。\n' ...
'你的任务是：对以下多个路面模量反演候选解进行物理合理性评分，帮助筛选出最符合工程实际的解。\n' ...
'FWD反演存在解的非唯一性问题（ASTM D5858 §5.2）：多个模量组合可产生近乎相同的弯沉盆，\n' ...
'因此需要借助工程规范知识来裁决候选解的物理可信度。\n\n' ...
...
'═══════════════ 路面基本信息 ═══════════════\n' ...
'路面类型: %s\n' ...
'各层厚度（面层/基层/底基层）: %s\n' ...
'测试荷载: %.1f kN\n' ...
'路面温度: %s\n' ...
'实测弯沉盆（D0~D150，单位mm）: %s\n\n' ...
...
'═══════════════ 候选反演解 ═══════════════\n' ...
'以下%d个候选解均满足弯沉匹配精度要求，但由于反演问题的非唯一性，\n' ...
'数学误差相近并不意味着物理上同样合理。请从工程知识角度进行判断：\n\n' ...
'%s\n' ...
...
'═══════════════ 工程知识（三层架构）═══════════════\n\n' ...
'%s\n\n' ...
'%s\n' ...
...
'═══════════════ 评分规则 ═══════════════\n' ...
'请对每个候选解按以下维度综合评分（总分10分）：\n\n' ...
'【维度1】模量绝对值的物理合理性（3分）\n' ...
'  - 对照上方的硬约束和软约束，判断各层模量是否在合理的物理范围内\n' ...
'  - 偏离规范典型值（RAG检索到的数值区间）时酌情扣分——偏离越大，扣分越多\n' ...
'  - 违反硬约束（如土基高于基层）→ 此项直接0分\n' ...
'  - 注意温度影响：温度越高，沥青层模量越低\n\n' ...
'【维度2】层间模量梯度的合理性（3分）\n' ...
'  - 对照硬约束第1条中的层间梯度规则\n' ...
'  - 半刚性路面：水泥稳定类基层可显著高于面层，属正常现象\n' ...
'  - 任何层的模量不应出现"下层刚度远超上层"的反常现象（半刚性路面除外）\n' ...
'  - 土基模量不得高于其上任何层\n\n' ...
'【维度3】弯沉盆匹配质量（2分）\n' ...
'  - 弯沉盆各测点误差应尽量均匀分布（非仅D0匹配极好但远端偏差大）\n' ...
'  - 远端测点（D90~D150）误差对深层模量影响更敏感，权重应更大\n' ...
'  - 参考ASTM D5858 §7.3.4：9传感器AASE容差为9~18%%\n\n' ...
'【维度4】对工程决策的适用性（2分）\n' ...
'  - 模量值在规范建议范围内，便于与JTG D50/AASHTO设计规范直接对接\n' ...
'  - 不存在"紧贴约束边界"的异常值（暗示优化未收敛到真实物理解）\n\n' ...
'═══════════════ 输出格式要求 ═══════════════\n' ...
'请严格按以下格式输出，不要输出其他内容：\n\n' ...
'<scores>\n' ...
'候选解1: X.X分 | 规范依据: [规范号-表号] | 理由: [不超过30字]\n' ...
'候选解2: X.X分 | 规范依据: [规范号-表号] | 理由: [不超过30字]\n' ...
'... （共%d行，每条必须注明所引用的规范编号和表号）\n' ...
'</scores>\n' ...
'<best>候选解N</best>\n' ...
'<reasoning>整体推荐理由（2~3句话，引用具体规范依据）</reasoning>\n' ...
'<citations>本评分引用的规范：逐一列出所用的规范号及表号</citations>\n'], ...
    pavement_desc, thickness_str, load_kN, temp_desc, ...
    sprintf('%.4f ', input_data.deflection_basin), ...
    n_solutions, solutions_summary, ...
    hard_constraints, rag_section, ...
    n_solutions);

end

%% ==================== 子函数：构建RAG查询字符串 ====================
function query = buildRAGQuery(pavement_desc, input_data, temp_val)
% 根据当前算例构建RAG检索查询

% 判断结构类型
if contains(lower(pavement_desc), 'semi') || ...
   contains(pavement_desc, '半刚性') || ...
   contains(pavement_desc, '无机结合料')
    struct_type = '半刚性路面 无机结合料稳定类基层';
else
    struct_type = '沥青路面';
end

% 温度分段描述
if temp_val <= 5
    temp_range = '低温';
elseif temp_val >= 30
    temp_range = '高温';
else
    temp_range = '常温';
end

% 路面类型判断：柔性/半刚性
if contains(lower(pavement_desc), 'flexible') || ...
   contains(pavement_desc, '柔性') || ...
   contains(pavement_desc, '粒料')
    base_type = '粒料基层 级配碎石';
elseif contains(lower(pavement_desc), 'semi') || ...
       contains(pavement_desc, '半刚性') || ...
       contains(pavement_desc, '无机')
    base_type = '水泥稳定碎石基层';
else
    base_type = '水泥稳定碎石基层';
end

% 查询中加入沥青面层关键词，确保 RAG 总能召回 AC 温度-模量知识
query = sprintf('%s %s %s %d度 沥青面层 AC模量 模量范围', struct_type, base_type, temp_range, round(temp_val));
end

%% ==================== 子函数：RAG不可用时的退回知识 ====================
function fallback = buildFallbackKnowledge(pavement_desc, temp_val)
% 当RAG检索服务不可用时，使用内置的带出处静态知识作为兜底
% 注意：此处的数值区间来自JTG D50-2017规范表格，已校准

if temp_val <= 5
    ac_range = '3000~6000 MPa（JTG D50-2017 表5.5.11, 20℃基准值, 低温取高值）';
elseif temp_val >= 30
    ac_range = '800~2000 MPa（JTG D50-2017 表5.5.11, 20℃基准值, 高温取低值）';
else
    ac_range = '1500~4000 MPa（JTG D50-2017 表5.5.11, 常温）';
end

fallback = sprintf([...
'[静态兜底知识——RAG检索服务未连接，使用内置规范知识]\n' ...
'1. 沥青混凝土面层动态压缩模量（JTG D50-2017 表5.5.11, 10Hz, 20℃基准）：\n' ...
'   AC10/AC13: 7000~12500 MPa（因沥青类型而异）；AC16/AC20/AC25: 7500~13500 MPa\n' ...
'   温度修正：当前%s，模量典型范围 %s\n' ...
'2. 水泥稳定碎石弹性模量（JTG D50-2017 表5.4.5, 室内值, 需×0.5调整）：\n' ...
'   水泥稳定粒料: 14000~28000 MPa（室内）→ FWD反算约 7000~14000 MPa\n' ...
'   水泥稳定土: 5000~7000 MPa（室内）→ FWD反算约 2500~3500 MPa\n' ...
'3. 粒料回弹模量（JTG D50-2017 表5.3.8, 湿度调整后）：\n' ...
'   级配碎石基层: 300~700 MPa；级配碎石底基层: 190~440 MPa\n' ...
'   级配砾石基层: 250~600 MPa；天然砂砾层: 130~240 MPa\n' ...
'4. 土基回弹模量（JTG D50-2017 表5.2.2）：\n' ...
'   极重交通≥70 MPa，特重≥60 MPa，重≥50 MPa，中等/轻≥40 MPa\n' ...
'5. 无机结合料7d无侧限抗压强度标准（JTG D50-2017 表5.4.4）：\n' ...
'   水泥稳定类基层（高速/一级）：极重特重5.0~7.0 MPa，重4.0~6.0，中等轻3.0~5.0\n'], ...
    sprintf('%.0f°C', temp_val), ac_range);
end

%% ==================== 子函数：解析LLM评分 ====================
function [selected_idx, scores, citations] = parseLLMScores(response, n_solutions)
% 从LLM响应中提取每个候选解的分数、引用和最高分索引
%
% 输出:
%   selected_idx - 最高分解索引
%   scores       - 各候选解评分数组
%   citations    - LLM引用的规范清单，若非空则证明"知识被显式使用"

scores = zeros(1, n_solutions);
citations = '';
sources_per_candidate = cell(1, n_solutions);

% 方法1：解析 <scores> 标签内的内容
scores_block = '';
score_match = regexp(response, '<scores>(.*?)</scores>', 'tokens', 'dotall');
if ~isempty(score_match)
    scores_block = score_match{1}{1};
else
    scores_block = response;  % 退而求其次，全文搜索
end

% 逐行匹配 "候选解N: X.X分"
for i = 1:n_solutions
    pattern = sprintf('候选解%d[^\\d]*([0-9]+\\.?[0-9]*)\\s*分', i);
    tok = regexp(scores_block, pattern, 'tokens');
    if ~isempty(tok)
        scores(i) = str2double(tok{1}{1});
    end
end

% 提取每个候选解的规范引用（用于验证LLM是否真正使用了给定知识）
for i = 1:n_solutions
    % 匹配 "规范依据: [xxx]" 中的内容
    pattern = sprintf('候选解%d[^|]*\\|\\s*规范依据[^:]*:\\s*([^|]+)', i);
    tok = regexp(scores_block, pattern, 'tokens');
    if ~isempty(tok)
        sources_per_candidate{i} = strtrim(tok{1}{1});
    end
end

% 方法2：若scores全零，尝试解析 <best> 标签
if all(scores == 0)
    best_match = regexp(response, '<best>[^0-9]*([0-9]+)', 'tokens');
    if ~isempty(best_match)
        best_n = str2double(best_match{1}{1});
        if best_n >= 1 && best_n <= n_solutions
            scores(best_n) = 10;  % 给最高分
        end
    end
end

% 选出最高分
[~, selected_idx] = max(scores);

% 打印reasoning（若有）
reasoning_match = regexp(response, '<reasoning>(.*?)</reasoning>', 'tokens', 'dotall');
if ~isempty(reasoning_match)
    fprintf('\n  [LLM推荐理由] %s\n', strtrim(reasoning_match{1}{1}));
end

% 提取并打印引用清单（若LLM输出了）
citations_match = regexp(response, '<citations>(.*?)</citations>', 'tokens', 'dotall');
if ~isempty(citations_match)
    citations = strtrim(citations_match{1}{1});
    fprintf('\n  [LLM引用规范] %s\n', citations);
end

% 打印逐条引用（验证知识可追溯）
for i = 1:n_solutions
    if ~isempty(sources_per_candidate{i})
        fprintf('   候选解%d 依据: %s\n', i, sources_per_candidate{i});
    end
end

end

%% ==================== 子函数：退回策略（最小D0误差）====================
function selected_idx = fallbackByMinError(all_solutions, n_solutions)
errors = zeros(1, n_solutions);
for i = 1:n_solutions
    errors(i) = all_solutions(i).D0_error;
end
[~, selected_idx] = min(errors);
fprintf('  [退回策略] 选择D0误差最小解: 第%d次运行 (%.2f%%)\n', ...
    all_solutions(selected_idx).run_idx, errors(selected_idx)*100);
end

%% ==================== 子函数：保存评分日志 ====================
function saveScoringLog(all_solutions, n_solutions, scores, selected_idx, llm_response, citations, input_data)
log_dir = 'output/multirun_logs';
if ~exist(log_dir, 'dir'), mkdir(log_dir); end

timestamp = datestr(now, 'yyyymmdd_HHMMSS');
log_file = fullfile(log_dir, sprintf('multirun_selection_%s.json', timestamp));

log_data = struct();
log_data.timestamp = datestr(now, 'yyyy-mm-dd HH:MM:SS');
% ✅ 修复代码
if isfield(input_data, 'pavement_type_name')
    log_data.pavement_type = input_data.pavement_type_name;
elseif isfield(input_data, 'pavement_type')
    log_data.pavement_type = input_data.pavement_type;
else
    log_data.pavement_type = 'semi_rigid';
end
log_data.n_candidates = n_solutions;
log_data.selected_run_idx = all_solutions(selected_idx).run_idx;
log_data.llm_scores = scores;
log_data.llm_response = llm_response;
log_data.citations = citations;  % LLM引用的规范清单——验证"知识被显式使用"的关键证据

candidates = cell(1, n_solutions);
for i = 1:n_solutions
    c = struct();
    c.run_idx = all_solutions(i).run_idx;
    c.AC = round(all_solutions(i).modulus.surface);
    c.BC = round(all_solutions(i).modulus.base);
    c.SB = round(all_solutions(i).modulus.subbase);
    c.SG = round(all_solutions(i).modulus.subgrade);
    c.D0_error_pct = all_solutions(i).D0_error * 100;
    c.basin_error_pct = all_solutions(i).basin_error;
    c.llm_score = scores(i);
    candidates{i} = c;
end
log_data.candidates = candidates;

try
    json_str = jsonencode(log_data);
    fid = fopen(log_file, 'w', 'n', 'UTF-8');
    if fid > 0
        fprintf(fid, '%s', json_str);
        fclose(fid);
        fprintf('  [LOG] Multi-Run评分日志已保存: %s\n', log_file);
    end
catch
    fprintf('  [LOG] 日志保存失败（不影响主流程）\n');
end
end

%% ==================== 子函数：旧硬编码 prompt（无规范出处，供消融对照）====================
function prompt = buildOldHardcodedPrompt(solutions_summary, input_data, n_solutions, ...
    pavement_desc, thickness_str, load_kN, temp_desc)
% 改造前的旧 prompt——无规范出处、无 RAG、无 rule_id 引用要求
% 用于消融实验 V9（对照）和所有 use_explicit_knowledge=false 的变体

prompt = sprintf([...
'你是一位路面结构工程专家，精通沥青路面和半刚性路面的力学特性。\n' ...
'你的任务是：对以下多个路面模量反演候选解进行物理合理性评分，帮助筛选出最符合工程实际的解。\n\n' ...
...
'═══════════════ 路面基本信息 ═══════════════\n' ...
'路面类型: %s\n' ...
'各层厚度（面层/基层/底基层）: %s\n' ...
'测试荷载: %.1f kN\n' ...
'路面温度: %s\n' ...
'实测弯沉盆（D0~D150，单位mm）: %s\n\n' ...
...
'═══════════════ 候选反演解 ═══════════════\n' ...
'以下%d个候选解均满足弯沉匹配精度要求，但由于反演问题的非唯一性，\n' ...
'数学误差相近并不意味着物理上同样合理。请从工程知识角度进行判断：\n\n' ...
'%s\n' ...
...
'═══════════════ 评分规则 ═══════════════\n' ...
'请对每个候选解按以下维度综合评分（总分10分）：\n\n' ...
'【维度1】模量绝对值的合理性（3分）\n' ...
'  - 沥青混凝土面层（AC）：正常范围约1000~6000 MPa；温度越高模量越低\n' ...
'    低温（<5°C）：3000~6000 MPa；常温（10~25°C）：1500~4000 MPa；高温（>30°C）：800~2000 MPa\n' ...
'  - 水泥稳定碎石基层（CTB/CSM）：正常范围约1000~8000 MPa\n' ...
'  - 级配碎石/无结合料基层：正常范围约150~600 MPa\n' ...
'  - 底基层：通常低于基层，50~500 MPa\n' ...
'  - 土基：通常20~150 MPa，路基稳定性好时可达200 MPa\n\n' ...
'【维度2】层间模量梯度的合理性（3分）\n' ...
'  - 沥青路面：面层 > 底基层 > 土基（面层一般最高）\n' ...
'  - 半刚性路面：基层可显著高于面层（水泥稳定材料刚度更大）\n' ...
'  - 任何层的模量不应出现"下层远大于上层"的反常现象（半刚性路面除外）\n' ...
'  - 土基模量不应高于底基层\n\n' ...
'【维度3】弯沉盆匹配的整体质量（2分）\n' ...
'  - 优先考虑弯沉盆各测点误差均匀（非仅D0匹配好但远端测点偏差大）\n' ...
'  - 远端测点（D90~D150）误差对深层模量影响敏感，权重更大\n\n' ...
'【维度4】对工程决策的适用性（2分）\n' ...
'  - 模量值在标准范围内，便于与设计规范对应\n' ...
'  - 不存在极端异常值（如某层模量为最小约束值或最大约束值，暗示优化未收敛到真实解）\n\n' ...
'═══════════════ 输出格式要求 ═══════════════\n' ...
'请严格按以下格式输出，不要输出其他内容：\n\n' ...
'<scores>\n' ...
'候选解1: X.X分 | 理由：[简短理由，不超过30字]\n' ...
'候选解2: X.X分 | 理由：[简短理由，不超过30字]\n' ...
'... （共%d行）\n' ...
'</scores>\n' ...
'<best>候选解N</best>\n' ...
'<reasoning>整体推荐理由（2~3句话，说明为何该解最符合工程实际）</reasoning>\n'], ...
    pavement_desc, thickness_str, load_kN, temp_desc, ...
    sprintf('%.4f ', input_data.deflection_basin), ...
    n_solutions, solutions_summary, n_solutions);

end
