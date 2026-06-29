function initial_modulus = initialModulusGenerator(input_data, config, method)
% INITIALMODULUSGENERATOR - 初始模量估计器 v5.5
%
% 【v5.5更新】⚠️ 半刚性结构支持增强
%   1. 新增半刚性结构专用经验公式（基于RingRoad数据）
%   2. 半刚性基层模量范围：5000-15000 MPa（水泥稳定碎石）
%   3. 半刚性底基层模量范围：1500-5000 MPa（水泥土）
%   4. 增强弯沉盆形状特征分析
%
% 【v5.4更新】
%   1. 修复柔性路面初始估计，使其更接近真实值
%   2. 增强层间比例约束
%   3. 优化弯沉指数推算公式
%
% 功能:
%   根据实测弯沉和路面类型生成合理的初始模量估计
%
% 输入:
%   input_data - 输入数据结构体
%   config     - 配置结构体
%   method     - 方法: 'empirical', 'hybrid', 'llm'
%
% 输出:
%   initial_modulus - 初始模量结构体
%       .surface    - 表面层模量 (MPa)
%       .base       - 基层模量 (MPa)
%       .subbase    - 底基层模量 (MPa)
%       .subgrade   - 土基模量 (MPa)

if nargin < 3, method = 'empirical'; end

fprintf('  ═══════════════════════════════════════════════════════════\n');
fprintf('    初始模量估计器 v5.5 (半刚性增强版) 方法: %s\n', method);
fprintf('  ═══════════════════════════════════════════════════════════\n');

% 1. 识别路面类型，统一标准化为字符串
if isfield(input_data, 'pavement_type')
    raw_type = input_data.pavement_type;
    % 支持数字编码（1=flexible, 2=semi_rigid, 3=inverted）
    if isnumeric(raw_type)
        switch raw_type
            case 2,  pavement_type = 'semi_rigid';
            case 3,  pavement_type = 'inverted';
            otherwise, pavement_type = 'flexible';
        end
    else
        % 字符串：统一小写+下划线
        pt_str = lower(strrep(char(raw_type), '-', '_'));
        if contains(pt_str, 'semi')
            pavement_type = 'semi_rigid';
        elseif contains(pt_str, 'inv')
            pavement_type = 'inverted';
        elseif contains(pt_str, 'rigid_comp')
            pavement_type = 'rigid_composite';
        else
            pavement_type = 'flexible';
        end
    end
else
    % 根据弯沉自动识别
    D0_um = input_data.measured_deflection * 1000;
    if D0_um < 100
        pavement_type = 'semi_rigid';
    elseif D0_um < 400
        pavement_type = 'medium';
    else
        pavement_type = 'flexible';
    end
end

fprintf('  📋 路面类型: %s\n', pavement_type);
fprintf('  📋 目标D0: %.4f mm (%.0f μm)\n', input_data.measured_deflection, input_data.measured_deflection*1000);

% 2. 获取约束范围
if isfield(input_data, 'modulus_constraints')
    constraints = convertConstraints(input_data.modulus_constraints);
elseif isfield(input_data, 'modulus_bounds')
    constraints = convertBounds(input_data.modulus_bounds);
else
    constraints = getDefaultConstraints_v55(pavement_type, input_data.measured_deflection);
end

fprintf('  📋 约束范围:\n');
fprintf('      表面层: [%d, %d] MPa\n', constraints.surface_layer_min, constraints.surface_layer_max);
fprintf('      基层:   [%d, %d] MPa\n', constraints.base_layer_min, constraints.base_layer_max);
fprintf('      底基层: [%d, %d] MPa\n', constraints.subbase_layer_min, constraints.subbase_layer_max);
fprintf('      土基:   [%d, %d] MPa\n', constraints.subgrade_min, constraints.subgrade_max);

% 3. 生成初始估计
switch lower(method)
    case 'empirical'
        initial_modulus = generateEmpirical_v55(input_data, pavement_type, constraints);
        
    case 'hybrid'
        % 先尝试LLM，失败则用经验公式
        try
            initial_modulus = generateWithLLM(input_data, config, pavement_type, constraints);
        catch ME
            fprintf('  ⚠️ LLM估计失败: %s，使用经验公式\n', ME.message);
            initial_modulus = generateEmpirical_v55(input_data, pavement_type, constraints);
        end
        
    case 'llm'
        initial_modulus = generateWithLLM(input_data, config, pavement_type, constraints);
        
    otherwise
        initial_modulus = generateEmpirical_v55(input_data, pavement_type, constraints);
end

% 4. 添加元信息
initial_modulus.pavement_type = pavement_type;
initial_modulus.constraints = constraints;
initial_modulus.method = method;


fprintf('\n  ✅ 初始模量估计完成:\n');
fprintf('      表面层: %d MPa\n', initial_modulus.surface);
fprintf('      基层:   %d MPa\n', initial_modulus.base);
fprintf('      底基层: %d MPa\n', initial_modulus.subbase);
fprintf('      土基:   %d MPa\n', initial_modulus.subgrade);

% 计算层间比例
fprintf('  📊 层间比例:\n');
fprintf('      表面层/基层: %.2f\n', initial_modulus.surface / initial_modulus.base);
fprintf('      基层/底基层: %.2f\n', initial_modulus.base / initial_modulus.subbase);
fprintf('      底基层/土基: %.2f\n', initial_modulus.subbase / initial_modulus.subgrade);

fprintf('  ═══════════════════════════════════════════════════════════\n\n');

end

%% ==================== v5.5增强版经验公式 ====================
function initial_modulus = generateEmpirical_v55(input_data, pavement_type, constraints)
% v5.5增强版经验公式 - 根据弯沉和路面类型估计模量

D0_mm = input_data.measured_deflection;
D0_um = D0_mm * 1000;

% 获取弯沉盆特征
if isfield(input_data, 'deflection_basin') && length(input_data.deflection_basin) >= 7
    basin = input_data.deflection_basin;
    
    % SCI (Surface Curvature Index) - 反映表面层刚度
    SCI = basin(1) - basin(3);  % D0 - D30
    
    % BDI (Base Damage Index) - 反映基层刚度
    if length(basin) >= 4
        BDI = basin(3) - basin(4);  % D30 - D60
    else
        BDI = SCI * 0.5;
    end
    
    % BCI (Base Curvature Index) - 反映底基层刚度
    if length(basin) >= 5
        BCI = basin(4) - basin(5);  % D60 - D90
    else
        BCI = BDI * 0.5;
    end
    
    % 衰减比 - 反映深层刚度
    decay_ratio = basin(end) / basin(1);
    
    % 【v5.5新增】近场衰减比 - 半刚性特征
    D20_D0_ratio = basin(2) / basin(1);
else
    % 无弯沉盆数据时使用估计值
    SCI = D0_mm * 0.3;
    BDI = D0_mm * 0.15;
    BCI = D0_mm * 0.08;
    decay_ratio = 0.3;
    D20_D0_ratio = 0.85;
end

fprintf('  📊 弯沉盆特征:\n');
fprintf('      SCI=%.4f, BDI=%.4f, BCI=%.4f\n', SCI, BDI, BCI);
fprintf('      衰减比=%.2f, D20/D0=%.2f\n', decay_ratio, D20_D0_ratio);

% 根据路面类型和弯沉特征估计模量
switch pavement_type
    case 'flexible'
        % ═══════════════════════════════════════════════════════════════════
        % 柔性路面经验公式
        % ═══════════════════════════════════════════════════════════════════
        % 参考值：D0=0.635mm时，AC=2000, BC=600, SB=200, SG=40
        
        % 表面层：根据SCI估计
        ref_SCI = 0.174;
        SCI_ratio = SCI / ref_SCI;
        E_surface_base = 2000;
        E_surface = E_surface_base / (SCI_ratio^0.4);
        
        % 基层：根据BDI估计
        ref_BDI = 0.06;
        BDI_ratio = BDI / max(ref_BDI, 0.01);
        E_base_base = 600;
        E_base = E_base_base / (BDI_ratio^0.35);
        
        % 底基层：与基层保持合理比例
        E_subbase = E_base / 3.0;
        
        % 土基：根据衰减比估计
        ref_decay = 0.35;
        decay_factor = decay_ratio / ref_decay;
        E_subgrade_base = 40;
        E_subgrade = E_subgrade_base / (decay_factor^0.5);
        
        % 修正因子：根据整体弯沉水平调整
        D0_factor = (0.635 / D0_mm)^0.3;
        E_surface = E_surface * D0_factor;
        E_base = E_base * D0_factor;
        E_subbase = E_subbase * D0_factor;
        
    case 'semi_rigid'
        % ═══════════════════════════════════════════════════════════════════
        % 【v5.5新增】半刚性路面专用经验公式
        % ═══════════════════════════════════════════════════════════════════
        % 半刚性特点：
        %   - D0很小（30-100 μm）
        %   - D20/D0比例高（85-98%，弯沉盆平缓）
        %   - 基层模量高（水泥稳定碎石 5000-15000 MPa）
        %   - 底基层模量中等（水泥土 1500-5000 MPa）
        % ───────────────────────────────────────────────────────────────────
        
        fprintf('  📋 使用半刚性专用公式 (v5.5)\n');
        
        % 根据D0和弯沉盆形状估计
        if D0_um < 50
            % 非常高刚度（D0 < 50μm）
            E_surface = 10000;
            E_base = 12000;      % 基层可能比沥青层还硬
            E_subbase = 3500;
            E_subgrade = 120;
            
        elseif D0_um < 70
            % 高刚度（50-70 μm）
            E_surface = 8000;
            E_base = 10000;
            E_subbase = 3000;
            E_subgrade = 100;
            
        elseif D0_um < 100
            % 中高刚度（70-100 μm）
            E_surface = 6000;
            E_base = 8000;
            E_subbase = 2500;
            E_subgrade = 80;
            
        else
            % 中等刚度（100+ μm，可能是老化或薄沥青层）
            E_surface = 5000;
            E_base = 6000;
            E_subbase = 2000;
            E_subgrade = 70;
        end
        
        % 根据D20/D0比例调整（比例越高说明基层越硬）
        if D20_D0_ratio > 0.95
            % 极高刚度基层
            E_base = E_base * 1.2;
            E_subbase = E_subbase * 1.1;
        elseif D20_D0_ratio > 0.90
            % 高刚度基层
            E_base = E_base * 1.1;
        elseif D20_D0_ratio < 0.80
            % 基层可能有损伤
            E_base = E_base * 0.8;
            E_subbase = E_subbase * 0.9;
        end
        
        % 根据远端衰减调整土基
        if decay_ratio > 0.6
            % 远端弯沉大，土基软
            E_subgrade = E_subgrade * 0.8;
        elseif decay_ratio < 0.4
            % 远端弯沉小，土基硬
            E_subgrade = E_subgrade * 1.2;
        end
        
        % 【v5.5修正】优先使用input_data中CSV传入的土基模量，避免硬编码偏差
        if isfield(input_data, 'subgrade_modulus') && input_data.subgrade_modulus > 0
            E_subgrade = input_data.subgrade_modulus;
            fprintf('  📋 使用CSV传入的土基模量: %d MPa\n', E_subgrade);
        end
        
    case 'rigid_composite'
        % ═══════════════════════════════════════════════════════════════════
        % 刚性复合路面
        % ═══════════════════════════════════════════════════════════════════
        E_surface = 15000;
        E_base = 30000;
        E_subbase = 12000;
        E_subgrade = 150;
        
    case 'inverted'
        % ═══════════════════════════════════════════════════════════════════
        % 倒装式路面
        % ═══════════════════════════════════════════════════════════════════
        if D0_um < 60
            E_surface = 12000;
            E_base = 500;
            E_subbase = 300;
            E_subgrade = 120;
        else
            E_surface = 10000;
            E_base = 400;
            E_subbase = 250;
            E_subgrade = 100;
        end
        
    case 'medium'
        % ═══════════════════════════════════════════════════════════════════
        % 中等刚度路面
        % ═══════════════════════════════════════════════════════════════════
        E_surface = 4000 * (100 / D0_um)^0.35;
        E_base = 1200 * (100 / D0_um)^0.30;
        E_subbase = 400 * (100 / D0_um)^0.25;
        E_subgrade = 80 * (100 / D0_um)^0.20;
        
    otherwise
        % ═══════════════════════════════════════════════════════════════════
        % 通用公式
        % ═══════════════════════════════════════════════════════════════════
        E_surface = 3000 * (100 / D0_um)^0.4;
        E_base = 1500 * (100 / D0_um)^0.35;
        E_subbase = 300 * (100 / D0_um)^0.3;
        E_subgrade = 80 * (100 / D0_um)^0.25;
end

% 约束截断
initial_modulus.surface = constrainValue(round(E_surface/50)*50, constraints.surface_layer_min, constraints.surface_layer_max);
initial_modulus.base = constrainValue(round(E_base/50)*50, constraints.base_layer_min, constraints.base_layer_max);
initial_modulus.subbase = constrainValue(round(E_subbase/50)*50, constraints.subbase_layer_min, constraints.subbase_layer_max);
initial_modulus.subgrade = constrainValue(round(E_subgrade/10)*10, constraints.subgrade_min, constraints.subgrade_max);

end

%% ==================== LLM辅助估计 ====================
function initial_modulus = generateWithLLM(input_data, config, pavement_type, constraints)
% 使用LLM辅助生成初始估计

D0_mm = input_data.measured_deflection;

% 构建弯沉盆信息
basin_str = '';
if isfield(input_data, 'deflection_basin')
    basin_str = sprintf('弯沉盆: [%s] mm', sprintf('%.4f ', input_data.deflection_basin));
end

% 构建prompt
% 根据路面类型设定专家角色和材料知识
switch pavement_type
    case 'semi_rigid'
        role_str = ['a senior pavement structural engineer specializing in ' ...
            'semi-rigid base pavement systems. In semi-rigid pavements, ' ...
            'the cement-stabilized macadam (CSM/CTB) base layer exhibits ' ...
            'modulus of 3,000–15,000 MPa, which EXCEEDS the AC surface ' ...
            'layer modulus. This is physically correct and expected.'];
        material_knowledge = [...
            'Material-specific knowledge for semi-rigid pavement:\n' ...
            '  - AC surface layer: 1,500–6,000 MPa (temperature-dependent)\n' ...
            '  - CSM/CTB base layer: 3,000–15,000 MPa (HIGHER than AC is normal)\n' ...
            '  - Cement-treated subbase: 800–4,000 MPa\n' ...
            '  - Subgrade: 30–150 MPa\n' ...
            '  Key characteristic: BC modulus SHOULD exceed AC modulus.\n'];
    case 'inverted'
        role_str = ['a senior pavement structural engineer specializing in ' ...
            'inverted pavement structures, where a stiff crushed-stone base ' ...
            'underlies a thin asphalt surface layer.'];
        material_knowledge = [...
            'Material-specific knowledge for inverted pavement:\n' ...
            '  - AC surface layer: 1,500–5,000 MPa\n' ...
            '  - Granular base layer: 150–600 MPa (LOWER than surface)\n' ...
            '  - Subbase: 80–400 MPa\n' ...
            '  - Subgrade: 30–120 MPa\n' ...
            '  Key characteristic: stiffness does NOT decrease monotonically.\n'];
    otherwise  % flexible, medium
        role_str = ['a senior pavement structural engineer specializing in ' ...
            'conventional flexible pavement systems with asphalt concrete ' ...
            'surface over granular base and subbase layers.'];
        material_knowledge = [...
            'Material-specific knowledge for flexible pavement:\n' ...
            '  - AC surface layer: 800–6,500 MPa (temperature-dependent; lower at high temp)\n' ...
            '  - Granular base layer: 150–2,000 MPa\n' ...
            '  - Granular subbase: 50–700 MPa\n' ...
            '  - Subgrade: 20–180 MPa\n' ...
            '  Key characteristic: stiffness decreases with depth (AC > BC > SB > SG).\n'];
end

% 构建弯沉盆信息
basin_str = '';
if isfield(input_data, 'deflection_basin') && length(input_data.deflection_basin) >= 3
    d = input_data.deflection_basin;
    SCI = d(1) - d(3);   % Surface Curvature Index (D0-D30): reflects AC stiffness
    BDI = d(3) - d(4);   % Base Damage Index (D30-D60): reflects base condition
    BCI = d(4) - d(5);   % Base Curvature Index (D60-D90): reflects subbase condition
    decay = d(end)/d(1); % Far-field decay ratio: reflects subgrade stiffness
    basin_str = sprintf(['Deflection basin [D0,D20,D30,D60,D90,D120,D150]: [%s] mm\n' ...
        '  SCI (D0-D30)=%.4f mm — high value → stiff AC; low → weak surface\n' ...
        '  BDI (D30-D60)=%.4f mm — high value → weak base layer\n' ...
        '  BCI (D60-D90)=%.4f mm — high value → weak subbase\n' ...
        '  Decay ratio (D150/D0)=%.2f — low value → stiff subgrade\n'], ...
        sprintf('%.4f ', d), SCI, BDI, BCI, decay);
end

% 构建prompt
prompt = sprintf([...
    'You are %s\n\n' ...
    '[Pavement Structure Information]\n' ...
    'Pavement type: %s\n' ...
    'Layer thicknesses (surface/base/subbase): %.1f cm / %.1f cm / %.1f cm\n' ...
    'Measured center deflection D0: %.4f mm\n' ...
    '%s\n' ...
    '[%s]\n\n' ...
    '[Feasible Modulus Bounds]\n' ...
    'AC surface layer: [%d, %d] MPa\n' ...
    'Base course (BC): [%d, %d] MPa\n' ...
    'Subbase (SB): [%d, %d] MPa\n' ...
    'Subgrade (SG): [%d, %d] MPa\n\n' ...
    '[Task]\n' ...
    'Using the deflection basin shape indicators above and your pavement-type-specific ' ...
    'material knowledge, estimate physically plausible initial moduli for backcalculation.\n' ...
    'High SCI → prioritize increasing AC modulus estimate.\n' ...
    'High BDI → prioritize reducing base modulus estimate.\n' ...
    'Low decay ratio → increase subgrade modulus estimate.\n\n' ...
    '[IMPORTANT] Respond ONLY in this exact format:\n' ...
    'MODULUS: AC=XXXX, BC=XXXX, SB=XXX, SG=XX\n'], ...
    role_str, ...
    pavement_type, ...
    input_data.thickness(1), input_data.thickness(2), input_data.thickness(3), ...
    D0_mm, basin_str, material_knowledge, ...
    constraints.surface_layer_min, constraints.surface_layer_max, ...
    constraints.base_layer_min, constraints.base_layer_max, ...
    constraints.subbase_layer_min, constraints.subbase_layer_max, ...
    constraints.subgrade_min, constraints.subgrade_max);

% 调用LLM
response = callLLMAPI(prompt, config, config.llm_guidance.model);

if isempty(response)
    error('LLM响应为空');
end

fprintf('  LLM响应: %s\n', strtrim(response(1:min(200, length(response)))));

% 解析响应
pattern = 'MODULUS:\s*AC\s*=\s*(\d+),?\s*BC\s*=\s*(\d+),?\s*SB\s*=\s*(\d+),?\s*SG\s*=\s*(\d+)';
tokens = regexp(response, pattern, 'tokens');

if ~isempty(tokens)
    vals = tokens{1};
    initial_modulus.surface = str2double(vals{1});
    initial_modulus.base = str2double(vals{2});
    initial_modulus.subbase = str2double(vals{3});
    initial_modulus.subgrade = str2double(vals{4});
    
    % 约束截断
    initial_modulus.surface = constrainValue(initial_modulus.surface, constraints.surface_layer_min, constraints.surface_layer_max);
    initial_modulus.base = constrainValue(initial_modulus.base, constraints.base_layer_min, constraints.base_layer_max);
    initial_modulus.subbase = constrainValue(initial_modulus.subbase, constraints.subbase_layer_min, constraints.subbase_layer_max);
    initial_modulus.subgrade = constrainValue(initial_modulus.subgrade, constraints.subgrade_min, constraints.subgrade_max);
    
    fprintf('  ✓ LLM估计解析成功\n');
else
    error('无法解析LLM响应');
end

end

%% ==================== 约束获取 【v5.5更新】 ====================
function constraints = getDefaultConstraints_v55(pavement_type, D0_mm)
    % 【v5.5修复】根据路面类型获取默认约束 - 半刚性范围大幅扩展
    
    D0_um = D0_mm * 1000;
    
    switch pavement_type
        case 'semi_rigid'
            % 【v5.5关键修改】半刚性结构约束范围
            % 基层: 水泥稳定碎石(CBG) 5000-15000 MPa（规范值可达30GPa）
            % 底基层: 水泥土(CS) 1500-5000 MPa
            constraints.surface_layer_min = 3000;   constraints.surface_layer_max = 15000;
            constraints.base_layer_min = 5000;      constraints.base_layer_max = 18000;  % 扩大上限
            constraints.subbase_layer_min = 1500;   constraints.subbase_layer_max = 6000;  % 水泥土范围
            constraints.subgrade_min = 40;          constraints.subgrade_max = 200;
            
        case 'rigid_composite'
            constraints.surface_layer_min = 5000;   constraints.surface_layer_max = 25000;
            constraints.base_layer_min = 25000;     constraints.base_layer_max = 40000;
            constraints.subbase_layer_min = 8000;   constraints.subbase_layer_max = 18000;
            constraints.subgrade_min = 60;          constraints.subgrade_max = 300;
            
        case 'inverted'
            constraints.surface_layer_min = 3000;   constraints.surface_layer_max = 15000;
            constraints.base_layer_min = 150;       constraints.base_layer_max = 800;
            constraints.subbase_layer_min = 80;     constraints.subbase_layer_max = 400;
            constraints.subgrade_min = 40;          constraints.subgrade_max = 200;
            
        case 'flexible'
            constraints.surface_layer_min = 800;    constraints.surface_layer_max = 6500;
            constraints.base_layer_min = 150;       constraints.base_layer_max = 2000;
            constraints.subbase_layer_min = 50;     constraints.subbase_layer_max = 700;
            constraints.subgrade_min = 20;          constraints.subgrade_max = 180;
            
        case 'medium'
            constraints.surface_layer_min = 1200;   constraints.surface_layer_max = 6500;
            constraints.base_layer_min = 300;       constraints.base_layer_max = 2000;
            constraints.subbase_layer_min = 100;    constraints.subbase_layer_max = 700;
            constraints.subgrade_min = 50;          constraints.subgrade_max = 180;
            
        otherwise
            constraints.surface_layer_min = 800;    constraints.surface_layer_max = 6500;
            constraints.base_layer_min = 150;       constraints.base_layer_max = 2000;
            constraints.subbase_layer_min = 50;     constraints.subbase_layer_max = 700;
            constraints.subgrade_min = 20;          constraints.subgrade_max = 180;
    end
end


%% ==================== 转换输入约束格式 ====================
function constraints = convertConstraints(input_constraints)
constraints.surface_layer_min = input_constraints.surface_min;
constraints.surface_layer_max = input_constraints.surface_max;
constraints.base_layer_min = input_constraints.base_min;
constraints.base_layer_max = input_constraints.base_max;
constraints.subbase_layer_min = input_constraints.subbase_min;
constraints.subbase_layer_max = input_constraints.subbase_max;
if isfield(input_constraints, 'subgrade_min')
    constraints.subgrade_min = input_constraints.subgrade_min;
    constraints.subgrade_max = input_constraints.subgrade_max;
else
    constraints.subgrade_min = 20;
    constraints.subgrade_max = 200;
end
end

%% ==================== 转换bounds格式 【v5.5新增】 ====================
function constraints = convertBounds(bounds)
% 将modulus_bounds格式转换为constraints格式
constraints.surface_layer_min = bounds.surface(1);
constraints.surface_layer_max = bounds.surface(2);
constraints.base_layer_min = bounds.base(1);
constraints.base_layer_max = bounds.base(2);
constraints.subbase_layer_min = bounds.subbase(1);
constraints.subbase_layer_max = bounds.subbase(2);
constraints.subgrade_min = bounds.subgrade(1);
constraints.subgrade_max = bounds.subgrade(2);
end



%% ==================== 辅助函数 ====================
function val = constrainValue(value, min_val, max_val)
val = max(min_val, min(max_val, value));
end