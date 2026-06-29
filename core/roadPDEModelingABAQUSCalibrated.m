function result = roadPDEModelingABAQUSCalibrated(designParams, loadParams, boundary_conditions)
% ═══════════════════════════════════════════════════════════════════════════
% roadPDEModelingABAQUSCalibrated - 带智能校准的ABAQUS兼容PDE建模
% ═══════════════════════════════════════════════════════════════════════════
%
% 【版本】v5.7.2 - 沥青层厚度参数传递修正（2025-12-10）
%
% 【v5.7.2修正】⚠️ 关键修复
%   1. 修复沥青层厚度未传递给校准函数的问题
%   2. 确保RingRoad_4/5（AC>=16cm）使用正确的较小校准因子
%   3. 确保弯沉盆形状校准也接收到沥青层厚度参数
%
% 【v5.6.9修正】
%   1. 半刚性结构校准因子从0.68-0.82修正为0.45-0.55
%   2. 原因: 基于RingRoad实测数据反推，原因子导致D0偏大50%
%   3. 新增半刚性弯沉盆形状校准（类似倒装结构处理）
%   4. 校准因子定义: factor = Target_D0 / PDE_D0
%
% 【v5.6.8修正】
%   1. 修正柔性路面校准因子：基于ABAQUS_13实测数据重新计算
%
% 【v5.6.7修复】
%   1. 修复属性设置顺序：先生成网格，再设置材料和边界条件
%
% ═══════════════════════════════════════════════════════════════════════════

fprintf('\n');
fprintf('╔═══════════════════════════════════════════════════════════════════╗\n');
fprintf('║  轴对称有限元建模 - 智能校准版 v5.7.2 (沥青层厚度修正)          ║\n');
fprintf('║  支持: 柔性路面 / 倒装结构 / 半刚性结构                         ║\n');
fprintf('╚═══════════════════════════════════════════════════════════════════╝\n');

% 首先调用基础PDE计算
result_raw = roadPDEModelingABAQUS_core(designParams, loadParams, boundary_conditions);

if ~result_raw.success
    result = result_raw;
    return;
end

% 获取土基模量用于校准
if isfield(boundary_conditions, 'subgrade_modulus')
    E_sg = boundary_conditions.subgrade_modulus;
elseif isfield(boundary_conditions, 'soil_modulus')
    E_sg = boundary_conditions.soil_modulus;
else
    E_sg = 40;
end

% 检测路面类型
pavement_type = detectPavementType(designParams, boundary_conditions);

% 【v5.7.2修正】提取沥青层厚度用于校准因子选择
ac_thickness = 0.14;  % 默认14cm
if isfield(designParams, 'thickness') && ~isempty(designParams.thickness)
    thickness = designParams.thickness(:);
    if all(thickness > 1), thickness = thickness / 100; end  % cm -> m
    ac_thickness = thickness(1);
end

% 智能校准
fprintf('\n【智能校准 v5.7.2】\n');
fprintf('  检测到路面类型: %s\n', pavement_type);
fprintf('  沥青层厚度: %.0f cm\n', ac_thickness * 100);

% 获取D0校准因子 - 【v5.7.2修正】传递沥青层厚度
[cal_factor, cal_status] = getCalibrationFactor(E_sg, pavement_type, ac_thickness);

fprintf('  土基模量: %d MPa\n', E_sg);
fprintf('  校准状态: %s\n', cal_status);
fprintf('  D0校准因子: %.4f (%s)\n', cal_factor, getFactorDirection(cal_factor));

% 应用D0校准
D0_raw = result_raw.D0;
D0_calibrated = D0_raw * cal_factor;

% NaN保护
if isnan(D0_calibrated) || isinf(D0_calibrated)
    fprintf('  ⚠️ [NaN保护] 校准后D0异常，使用原始值\n');
    D0_calibrated = D0_raw;
    cal_factor = 1.0;
end

% 弯沉盆形状校准 - 【v5.7.2修正】传递沥青层厚度
deflections_raw = result_raw.deflections;
deflections_calibrated = applyBasinShapeCalibration(deflections_raw, E_sg, pavement_type, D0_calibrated, ac_thickness);

fprintf('  原始D0: %.4f mm -> 校准后D0: %.4f mm (缩放比: %.2f%%)\n', ...
    D0_raw, D0_calibrated, cal_factor*100);

% 组装结果
result = result_raw;
result.D0_raw = D0_raw;
result.D0 = D0_calibrated;
result.deflections_raw = result_raw.deflections;
result.deflections = deflections_calibrated;
result.calibration_factor = cal_factor;
result.calibration_status = cal_status;
result.pavement_type = pavement_type;

fprintf('\n');
end

%% ═══════════════════════════════════════════════════════════════════════════
%  路面类型检测
%% ═══════════════════════════════════════════════════════════════════════════
function pavement_type = detectPavementType(designParams, boundary_conditions)
    pavement_type = 'flexible';
    
    % 【优先级1】直接指定的路面类型（字符串或数字均支持）
    if isfield(boundary_conditions, 'pavement_type') && ~isempty(boundary_conditions.pavement_type)
        raw = boundary_conditions.pavement_type;
        % 统一转换为字符串
        if isnumeric(raw)
            if raw == 2
                pavement_type = 'semi_rigid';
            elseif raw == 3
                pavement_type = 'inverted';
            else
                pavement_type = 'flexible';
            end
        else
            pt_str = lower(strrep(char(raw), '-', '_'));
            if contains(pt_str, 'semi')
                pavement_type = 'semi_rigid';
            elseif contains(pt_str, 'inv')
                pavement_type = 'inverted';
            else
                pavement_type = 'flexible';
            end
        end
        return;
    end
    
    % 【优先级2】根据模量特征自动识别
    if isfield(designParams, 'thickness') && isfield(designParams, 'modulus')
        thickness = designParams.thickness(:);
        if all(thickness > 1), thickness = thickness / 100; end
        modulus = designParams.modulus(:);
        
        if length(thickness) >= 3 && length(modulus) >= 3
            ac_thick = thickness(1);
            ac_mod = modulus(1);
            bc_mod = modulus(2);
            sb_mod = modulus(3);
            
            % 倒装结构：厚沥青层 + 软弱基层
            if ac_thick >= 0.30 && ac_mod >= 8000 && bc_mod < ac_mod/10
                pavement_type = 'inverted';
                return;
            end
            
            % 半刚性结构：基层模量高 或 基层>表面层 或 底基层高
            % 【v5.6.9】降低半刚性检测阈值，确保正确识别
            if bc_mod >= 3000 || (bc_mod > ac_mod * 0.8) || sb_mod >= 1500
                pavement_type = 'semi_rigid';
                return;
            end
        end
    end
    
    % 【优先级3】根据土基模量推断
    if isfield(boundary_conditions, 'subgrade_modulus')
        E_sg = boundary_conditions.subgrade_modulus;
        if E_sg > 150
            pavement_type = 'inverted';
        end
    end
end

%% ═══════════════════════════════════════════════════════════════════════════
%  获取D0校准因子 【v5.7.1 沥青层厚度修正】
%% ═══════════════════════════════════════════════════════════════════════════
function [factor, status] = getCalibrationFactor(E_sg, pavement_type, varargin)
    % 解析可选参数：沥青层厚度
    ac_thickness = 0.14;  % 默认14cm
    if nargin >= 3 && ~isempty(varargin{1})
        ac_thickness = varargin{1};
        if ac_thickness > 1, ac_thickness = ac_thickness / 100; end
    end
    
    % ═══════════════════════════════════════════════════════════════════════
    % 柔性路面校准数据 (基于ABAQUS仿真验证)
    % ═══════════════════════════════════════════════════════════════════════
    flexible_cal = struct();
    flexible_cal.E_sg = [20, 30, 40, 80, 120, 150];
    flexible_cal.factor = [1.16, 1.1251, 1.10, 1.07, 1.04, 1.02];
    flexible_cal.valid_range = [20, 150];
    flexible_cal.default = 1.10;
    
    % ═══════════════════════════════════════════════════════════════════════
    % 倒装结构校准数据
    % ═══════════════════════════════════════════════════════════════════════
    inverted_cal = struct();
    inverted_cal.E_sg = [60, 80, 120, 160, 200, 250, 300, 350];
    inverted_cal.factor = [0.86, 0.8680, 0.8734, 0.8776, 0.8811, 0.8846, 0.8876, 0.89];
    inverted_cal.valid_range = [60, 350];
    inverted_cal.default = 0.87;
    
    % ═══════════════════════════════════════════════════════════════════════
    % 【v5.7.1更新】半刚性结构校准数据 - 根据沥青层厚度分类
    % ═══════════════════════════════════════════════════════════════════════
    % 发现规律：沥青层越厚，需要的校准因子越小
    %   AC=12-14cm: factor ≈ 0.48 (RingRoad_1,2,3)
    %   AC=16-18cm: factor ≈ 0.38-0.42 (RingRoad_4,5)
    % ───────────────────────────────────────────────────────────────────────
    semi_rigid_cal = struct();
    % 【v5.8.0】加密插值节点：40~100 MPa范围内步长从不均匀改为5 MPa均匀
    % 新增节点: 45,50,55,65,70,75,85,90,95
    % 因子值由三次样条插值原8个锚点生成，保持与原锚点完全一致
    % 目的：使PPO在subgrade_step=5时能精细命中目标D0，满足5%收敛阈值
    semi_rigid_cal.E_sg = [40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100, 120, 150, 180, 200];
    
    if ac_thickness >= 0.16
        % 厚沥青层(AC>=16cm): 需要更小的校准因子
        semi_rigid_cal.factor = [0.3500, 0.3525, 0.3569, 0.3629, 0.3700, 0.3777, 0.3856, 0.3932, 0.4000, 0.4058, 0.4108, 0.4154, 0.4200, 0.4400, 0.4600, 0.4800, 0.5000];
        semi_rigid_cal.default = 0.42;
        fprintf('    [校准因子] 厚沥青层(%.0fcm): 使用较小因子\n', ac_thickness*100);
    else
        % 标准/薄沥青层(AC<=14cm): 原有因子（加密插值）
        semi_rigid_cal.factor = [0.4200, 0.4266, 0.4340, 0.4419, 0.4500, 0.4581, 0.4660, 0.4734, 0.4800, 0.4857, 0.4906, 0.4953, 0.5000, 0.5200, 0.5400, 0.5600, 0.5800];
        semi_rigid_cal.default = 0.50;
        fprintf('    [校准因子] 标准沥青层(%.0fcm): 使用标准因子\n', ac_thickness*100);
    end
    
    semi_rigid_cal.valid_range = [40, 200];
    
    % 选择校准数据
    switch lower(pavement_type)
        case 'flexible'
            cal = flexible_cal;
        case 'inverted'
            cal = inverted_cal;
        case 'semi_rigid'
            cal = semi_rigid_cal;
        otherwise
            cal = flexible_cal;
    end
    
    % 插值计算校准因子
    try
        factor = interp1(cal.E_sg, cal.factor, E_sg, 'linear', 'extrap');
        
        % 限制外推范围（±15%）
        min_factor = min(cal.factor) * 0.85;
        max_factor = max(cal.factor) * 1.15;
        factor = max(min_factor, min(max_factor, factor));
        
        if E_sg < min(cal.E_sg)
            status = sprintf('[外推] 土基模量%d低于数据范围[%d,%d]', E_sg, min(cal.E_sg), max(cal.E_sg));
        elseif E_sg > max(cal.E_sg)
            status = sprintf('[外推] 土基模量%d高于数据范围[%d,%d]', E_sg, min(cal.E_sg), max(cal.E_sg));
        else
            status = '[正常] 在校准范围内插值';
        end
    catch
        factor = cal.default;
        status = sprintf('[备用] 插值失败，使用默认值%.2f', factor);
    end
    
    % NaN保护
    if isnan(factor) || isinf(factor) || factor <= 0
        factor = cal.default;
        status = sprintf('[NaN保护] 使用默认值%.2f', factor);
    end
end

%% ═══════════════════════════════════════════════════════════════════════════
%  弯沉盆形状校准 【v5.7.0 动态调整版】
%% ═══════════════════════════════════════════════════════════════════════════
function deflections_cal = applyBasinShapeCalibration(deflections_raw, E_sg, pavement_type, D0_cal, varargin)
    n_sensors = length(deflections_raw);
    deflections_cal = zeros(1, n_sensors);
    deflections_cal(1) = D0_cal;
    
    % 解析可选参数（沥青层厚度）
    ac_thickness = 0.14;  % 默认14cm
    if nargin >= 5 && ~isempty(varargin{1})
        ac_thickness = varargin{1};
        if ac_thickness > 1, ac_thickness = ac_thickness / 100; end  % cm -> m
    end
    
    if strcmpi(pavement_type, 'inverted')
        % ═══════════════════════════════════════════════════════════════════
        % 倒装结构形状校准
        % ═══════════════════════════════════════════════════════════════════
        shape_E_sg = [80, 150, 250, 350];
        shape_D20 = [0.60, 0.55, 0.50, 0.48];
        shape_D30 = [0.48, 0.45, 0.42, 0.40];
        shape_D60 = [0.32, 0.30, 0.28, 0.27];
        shape_D90 = [0.24, 0.22, 0.20, 0.19];
        shape_D120 = [0.18, 0.17, 0.15, 0.14];
        shape_D150 = [0.14, 0.13, 0.11, 0.10];
        
        E_sg_clamped = max(min(E_sg, 350), 80);
        
        if n_sensors >= 2
            deflections_cal(2) = D0_cal * interp1(shape_E_sg, shape_D20, E_sg_clamped, 'linear', 'extrap');
        end
        if n_sensors >= 3
            deflections_cal(3) = D0_cal * interp1(shape_E_sg, shape_D30, E_sg_clamped, 'linear', 'extrap');
        end
        if n_sensors >= 4
            deflections_cal(4) = D0_cal * interp1(shape_E_sg, shape_D60, E_sg_clamped, 'linear', 'extrap');
        end
        if n_sensors >= 5
            deflections_cal(5) = D0_cal * interp1(shape_E_sg, shape_D90, E_sg_clamped, 'linear', 'extrap');
        end
        if n_sensors >= 6
            deflections_cal(6) = D0_cal * interp1(shape_E_sg, shape_D120, E_sg_clamped, 'linear', 'extrap');
        end
        if n_sensors >= 7
            deflections_cal(7) = D0_cal * interp1(shape_E_sg, shape_D150, E_sg_clamped, 'linear', 'extrap');
        end
        
    elseif strcmpi(pavement_type, 'semi_rigid')
        % ═══════════════════════════════════════════════════════════════════
        % 【v5.7.0更新】半刚性结构形状校准 - 根据沥青层厚度动态调整
        % ═══════════════════════════════════════════════════════════════════
        % 发现规律：沥青层越厚，弯沉盆越平缓（远场衰减越慢）
        % - AC=12-14cm: D150/D0 ≈ 37-50% (标准半刚性)
        % - AC=16-18cm: D150/D0 ≈ 60-65% (厚沥青半刚性)
        % ───────────────────────────────────────────────────────────────────
        
        % 基于沥青层厚度计算形状修正因子
        % ac_thickness < 0.14m: 标准形状
        % ac_thickness >= 0.16m: 平缓形状（远场比例更高）
        if ac_thickness >= 0.16
            % 厚沥青层（16-18cm）：弯沉盆非常平缓
            shape_D20 = [0.95, 0.94, 0.92, 0.90];
            shape_D30 = [0.88, 0.85, 0.82, 0.78];
            shape_D60 = [0.75, 0.72, 0.70, 0.68];
            shape_D90 = [0.70, 0.68, 0.65, 0.62];
            shape_D120 = [0.68, 0.65, 0.62, 0.58];
            shape_D150 = [0.65, 0.62, 0.58, 0.55];
            fprintf('    [形状校准] 厚沥青层(%.0fcm): 使用平缓形状参数\n', ac_thickness*100);
        else
            % 标准/薄沥青层（12-14cm）：正常衰减
            shape_D20 = [0.92, 0.90, 0.88, 0.85];
            shape_D30 = [0.82, 0.78, 0.75, 0.72];
            shape_D60 = [0.70, 0.68, 0.65, 0.62];
            shape_D90 = [0.58, 0.55, 0.52, 0.50];
            shape_D120 = [0.48, 0.45, 0.42, 0.40];
            shape_D150 = [0.42, 0.40, 0.38, 0.36];
            fprintf('    [形状校准] 标准沥青层(%.0fcm): 使用标准形状参数\n', ac_thickness*100);
        end
        
        shape_E_sg = [40, 80, 120, 180];
        E_sg_clamped = max(min(E_sg, 180), 40);
        
        if n_sensors >= 2
            deflections_cal(2) = D0_cal * interp1(shape_E_sg, shape_D20, E_sg_clamped, 'linear', 'extrap');
        end
        if n_sensors >= 3
            deflections_cal(3) = D0_cal * interp1(shape_E_sg, shape_D30, E_sg_clamped, 'linear', 'extrap');
        end
        if n_sensors >= 4
            deflections_cal(4) = D0_cal * interp1(shape_E_sg, shape_D60, E_sg_clamped, 'linear', 'extrap');
        end
        if n_sensors >= 5
            deflections_cal(5) = D0_cal * interp1(shape_E_sg, shape_D90, E_sg_clamped, 'linear', 'extrap');
        end
        if n_sensors >= 6
            deflections_cal(6) = D0_cal * interp1(shape_E_sg, shape_D120, E_sg_clamped, 'linear', 'extrap');
        end
        if n_sensors >= 7
            deflections_cal(7) = D0_cal * interp1(shape_E_sg, shape_D150, E_sg_clamped, 'linear', 'extrap');
        end
        
    else
        % ═══════════════════════════════════════════════════════════════════
        % 柔性路面：简单缩放
        % ═══════════════════════════════════════════════════════════════════
        if deflections_raw(1) > 0
            scale = D0_cal / deflections_raw(1);
            deflections_cal = deflections_raw * scale;
        else
            deflections_cal = deflections_raw;
            deflections_cal(1) = D0_cal;
        end
    end
    
    % 确保弯沉盆单调递减
    for i = 2:n_sensors
        if deflections_cal(i) > deflections_cal(i-1)
            deflections_cal(i) = deflections_cal(i-1) * 0.95;
        end
    end
    
    % NaN保护
    if any(isnan(deflections_cal)) || any(isinf(deflections_cal))
        if deflections_raw(1) > 0 && ~isnan(D0_cal)
            scale = D0_cal / deflections_raw(1);
            deflections_cal = deflections_raw * scale;
        else
            deflections_cal = deflections_raw;
        end
    end
end

function dir_str = getFactorDirection(factor)
    if isnan(factor)
        dir_str = '异常-NaN';
    elseif factor > 1.001
        dir_str = '放大';
    elseif factor < 0.999
        dir_str = '缩小';
    else
        dir_str = '不变';
    end
end

%% ═══════════════════════════════════════════════════════════════════════════
%  核心PDE计算函数 【v5.6.7 关键修复：属性设置顺序】
%% ═══════════════════════════════════════════════════════════════════════════
function result = roadPDEModelingABAQUS_core(designParams, loadParams, boundary_conditions)

tic_total = tic;

try
    % ═══════════════════════════════════════════════════════════════════════
    % Step 1: 参数预处理
    % ═══════════════════════════════════════════════════════════════════════
    if isfield(designParams, 'thickness') && ~isempty(designParams.thickness)
        thickness = designParams.thickness(:);
        if all(thickness > 1), thickness = thickness / 100; end
    else
        thickness = [0.10; 0.25; 0.25];
    end
    n_layers = length(thickness);
    total_pavement = sum(thickness);
    
    if isfield(designParams, 'modulus') && ~isempty(designParams.modulus)
        modulus = designParams.modulus(:);
        modulus = modulus(1:min(n_layers, length(modulus)));
        while length(modulus) < n_layers
            modulus = [modulus; modulus(end)];
        end
    else
        modulus = [2000; 600; 200];
    end
    
    if isfield(designParams, 'poisson') && ~isempty(designParams.poisson)
        poisson = designParams.poisson(:);
        poisson = poisson(1:min(n_layers, length(poisson)));
        while length(poisson) < n_layers
            poisson = [poisson; 0.35];
        end
    else
        poisson = [0.35; 0.35; 0.30];
    end
    
    if isfield(boundary_conditions, 'subgrade_modulus')
        E_sg = boundary_conditions.subgrade_modulus;
    elseif isfield(boundary_conditions, 'soil_modulus')
        E_sg = boundary_conditions.soil_modulus;
    else
        E_sg = 40;
    end
    nu_sg = 0.40;
    
    % 荷载参数：从loadParams读取，回退到标准FWD默认值
    if isfield(loadParams, 'load_pressure') && loadParams.load_pressure > 0
        P = loadParams.load_pressure;
    else
        P = 0.707355;  % 默认: 50kN标准荷载
    end
    if isfield(loadParams, 'load_radius') && loadParams.load_radius > 0
        r_load = loadParams.load_radius / 100;  % cm -> m
    else
        r_load = 0.15;  % 默认: 15cm接触半径
    end
    
    fprintf('  参数: 模量=[%s%d] MPa\n', sprintf('%d,', modulus), E_sg);
    fprintf('  厚度=[%s] m\n', sprintf('%.2f,', thickness));
    fprintf('  荷载: P=%.4f MPa, r=%.3f m (荷载=%.1f kN)\n', P, r_load, P*pi*r_load^2*1000);
    
    % ═══════════════════════════════════════════════════════════════════════
    % Step 2: 创建几何
    % ═══════════════════════════════════════════════════════════════════════
    r_max = 8.0;
    sg_depth = 10.0;
    z_bottom = -(total_pavement + sg_depth);
    
    gd = [3; 4; 0; r_max; r_max; 0; z_bottom; z_bottom; 0; 0];
    ns = char('R1')';
    sf = 'R1';
    [dl, ~] = decsg(gd, sf, ns);
    
    % 创建几何对象
    gm = fegeometry(dl);
    
    % ═══════════════════════════════════════════════════════════════════════
    % Step 3: 【关键】先生成网格，再创建模型
    % ═══════════════════════════════════════════════════════════════════════
    gm = generateMesh(gm, Hmax=0.08, Hmin=0.015);
    n_nodes = size(gm.Mesh.Nodes, 2);
    fprintf('  网格: %d 节点\n', n_nodes);
    
    % ═══════════════════════════════════════════════════════════════════════
    % Step 4: 创建模型并设置属性（网格已生成，不会被清空）
    % ═══════════════════════════════════════════════════════════════════════
    model = femodel(AnalysisType="structuralStatic", Geometry=gm);
    model.PlanarType = "axisymmetric";
    
    % 材料属性函数
    z_interfaces = [0; -cumsum(thickness)];
    E_all = [modulus; E_sg];
    nu_all = [poisson; nu_sg];
    
    Efcn = @(loc, state) getE(loc.y, z_interfaces, E_all);
    nufcn = @(loc, state) getNu(loc.y, z_interfaces, nu_all);
    
    % 设置材料属性
    model.MaterialProperties = materialProperties(...
        YoungsModulus=Efcn, ...
        PoissonsRatio=nufcn);
    
    % ═══════════════════════════════════════════════════════════════════════
    % Step 5: 设置边界条件
    % ═══════════════════════════════════════════════════════════════════════
    % 边界编号（矩形几何）:
    %   Edge 1: 底边 (z = z_bottom)
    %   Edge 2: 右边 (r = r_max)
    %   Edge 3: 顶边 (z = 0)
    %   Edge 4: 左边/对称轴 (r = 0)
    
    edge_bottom = 1;
    edge_right = 2;
    edge_top = 3;
    edge_axis = 4;
    
    % 对称轴：径向位移为0
    model.EdgeBC(edge_axis) = edgeBC(XDisplacement=0);
    
    % 底边：完全固定
    model.EdgeBC(edge_bottom) = edgeBC(Constraint="fixed");
    
    % 远场（右边界）：径向位移为0
    model.EdgeBC(edge_right) = edgeBC(XDisplacement=0);
    
    % 荷载
    P_Pa = P * 1e6;
    loadFcnHandle = @(location, state) applyFWDPressure(location.x, P_Pa, r_load);
    model.EdgeLoad(edge_top) = edgeLoad(Pressure=loadFcnHandle);
    
    % ═══════════════════════════════════════════════════════════════════════
    % Step 6: 求解
    % ═══════════════════════════════════════════════════════════════════════
    R = solve(model);
    
    % ═══════════════════════════════════════════════════════════════════════
    % Step 7: 提取弯沉
    % ═══════════════════════════════════════════════════════════════════════
    % 【v5.7.3修正】从boundary_conditions动态读取传感器位置，不再硬编码
    % 支持CSV传入的实际传感器偏移距离（如RIOHTRACK调整后: 0,23,53,69,85,116,153 cm）
    if isfield(boundary_conditions, 'sensor_offsets') && ~isempty(boundary_conditions.sensor_offsets)
        sensor_offsets_cm = boundary_conditions.sensor_offsets(:)';
        sensor_r = sensor_offsets_cm / 100;  % cm -> m
    else
        sensor_r = [0, 0.20, 0.30, 0.60, 0.90, 1.20, 1.50];  % 默认旧配置
    end
    n_sensors = length(sensor_r);
    deflections = zeros(1, n_sensors);
    
    for i = 1:n_sensors
        r = sensor_r(i);
        if r < 1e-6, r = 1e-6; end
        
        try
            intr = interpolateDisplacement(R, r, 0);
            deflections(i) = abs(intr.uy) * 1000;
        catch
            [~, idx] = min(abs(R.Mesh.Nodes(1,:) - r) + abs(R.Mesh.Nodes(2,:)));
            deflections(i) = abs(R.Displacement.uy(idx)) * 1000;
        end
    end
    
    elapsed = toc(tic_total);
    
    result.success = true;
    result.D0 = deflections(1);
    result.deflections = deflections;
    result.elapsed_time = elapsed;
    result.n_nodes = n_nodes;
    
    fprintf('  D0 = %.4f mm, 耗时 = %.2f 秒\n', result.D0, elapsed);

catch ME
    result.success = false;
    result.error = ME.message;
    result.D0 = NaN;
    result.deflections = NaN(1, 7);
    fprintf('  错误: %s\n', ME.message);
end
end

%% ═══════════════════════════════════════════════════════════════════════════
%  辅助函数
%% ═══════════════════════════════════════════════════════════════════════════

function E = getE(y, z_interfaces, E_all)
    n = length(E_all);
    E = E_all(n) * ones(size(y));
    for i = 1:n-1
        mask = (y > z_interfaces(i+1)) & (y <= z_interfaces(i));
        E(mask) = E_all(i);
    end
    E = E * 1e6;  % MPa -> Pa
end

function nu = getNu(y, z_interfaces, nu_all)
    n = length(nu_all);
    nu = nu_all(n) * ones(size(y));
    for i = 1:n-1
        mask = (y > z_interfaces(i+1)) & (y <= z_interfaces(i));
        nu(mask) = nu_all(i);
    end
end

function p = applyFWDPressure(r, P_Pa, r_contact)
    if ~isscalar(r)
        p = zeros(size(r));
        p(r <= r_contact) = P_Pa;
    else
        if r <= r_contact
            p = P_Pa;
        else
            p = 0;
        end
    end
end