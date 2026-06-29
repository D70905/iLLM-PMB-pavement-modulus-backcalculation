function test_cases = loadTestCases(group_name)
% LOADTESTCASES - 加载论文测试案例数据
%
% 功能：
%   加载ABAQUS仿真验证数据（15组柔性路面，有真实模量）
%   加载足尺环道实测数据（5组半刚性结构，无真值，用于通用性验证）
%
% 版本: v6.1.0 - ABAQUS + 环道数据集
%
% 使用方法：
%   test_cases = loadTestCases();           % 加载所有测试数据
%   test_cases = loadTestCases('ABAQUS');   % 加载ABAQUS组
%   test_cases = loadTestCases('RingRoad'); % 加载环道组
%   runTestCases('ABAQUS');                 % 运行ABAQUS全部15组
%   runTestCases('ABAQUS_1');               % 运行ABAQUS第1组
%   runTestCases('RingRoad');               % 运行环道全部5组
%   runTestCases('RingRoad_1');             % 运行环道第1组
%
% 数据来源：
%   - ABAQUS有限元仿真 + Python二次开发（15组柔性路面，有真值）
%   - 足尺环道FWD实测数据（5组半刚性结构，无真值）
%
% 作者：基于iLLM-PMB项目
% 日期：2025-12

if nargin < 1
    group_name = 'all';
end

fprintf('\n');
fprintf('╔════════════════════════════════════════════════════════════╗\n');
fprintf('║   论文测试数据加载器 v6.1.0 (ABAQUS+环道数据集)          ║\n');
fprintf('╚════════════════════════════════════════════════════════════╝\n\n');

test_cases = struct();

%% ════════════════════════════════════════════════════════════════════
%  ABAQUS仿真数据 - 15组柔性路面（全部有真实模量）
%  数据来源: flexible_structure.csv
%  结构类型: 薄沥青层(3) + 标准结构(3) + 厚沥青层(3) + 全厚式(3) + 薄面层(3)
%% ════════════════════════════════════════════════════════════════════

fprintf('加载 ABAQUS 仿真数据 (15组柔性路面)...\n\n');

% 传感器位置 (cm)
sensor_offsets = [0, 20, 30, 60, 90, 120, 150];

% -------------------- Case 1: 薄沥青层 --------------------
ABAQUS_1 = struct();
ABAQUS_1.name = 'ABAQUS_1';
ABAQUS_1.description = '薄沥青层 - ABAQUS仿真Case1';
ABAQUS_1.structure_type = 'ThinAC';
ABAQUS_1.structure_type_cn = '薄沥青层';

% 结构参数
ABAQUS_1.pavement_type = 'flexible';
ABAQUS_1.pavement_type_name = '柔性路面';  % [Fix] 补充llmSelectBestSolution所需字段
ABAQUS_1.thickness = [10; 25; 25];  % [AC, BC, SB] cm
ABAQUS_1.poisson = [0.35; 0.35; 0.35];

% 荷载参数 (标准FWD)
ABAQUS_1.load_pressure = 0.7;  % MPa
ABAQUS_1.load_radius = 15;     % cm

% 弯沉数据 (mm) - ABAQUS计算结果
ABAQUS_1.measured_deflection = 0.6353;
ABAQUS_1.deflection_basin = [0.6353, 0.5188, 0.4613, 0.3559, 0.2821, 0.2242, 0.1785];
ABAQUS_1.sensor_offsets = sensor_offsets;

% 【关键】真实模量值 - 用于计算反演精度
ABAQUS_1.true_modulus.surface = 2000;   % MPa
ABAQUS_1.true_modulus.base = 600;      % MPa
ABAQUS_1.true_modulus.subbase = 200;   % MPa
ABAQUS_1.true_modulus.subgrade = 40;  % MPa

% 土基模量初始值
ABAQUS_1.subgrade_modulus = 40;
ABAQUS_1.boundary_type = 'standard';

test_cases.ABAQUS_1 = ABAQUS_1;
fprintf('  ✓ ABAQUS_01 (薄沥青层): D0=0.6353mm, 真值=[2000,600,200,40]MPa\n');

% -------------------- Case 2: 薄沥青层 --------------------
ABAQUS_2 = struct();
ABAQUS_2.name = 'ABAQUS_2';
ABAQUS_2.description = '薄沥青层 - ABAQUS仿真Case2';
ABAQUS_2.structure_type = 'ThinAC';
ABAQUS_2.structure_type_cn = '薄沥青层';

% 结构参数
ABAQUS_2.pavement_type = 'flexible';
ABAQUS_2.pavement_type_name = '柔性路面';  % [Fix] 补充llmSelectBestSolution所需字段
ABAQUS_2.thickness = [10; 25; 25];  % [AC, BC, SB] cm
ABAQUS_2.poisson = [0.35; 0.35; 0.35];

% 荷载参数 (标准FWD)
ABAQUS_2.load_pressure = 0.7;  % MPa
ABAQUS_2.load_radius = 15;     % cm

% 弯沉数据 (mm) - ABAQUS计算结果
ABAQUS_2.measured_deflection = 0.3598;
ABAQUS_2.deflection_basin = [0.3598, 0.2879, 0.2518, 0.1877, 0.1455, 0.1138, 0.0894];
ABAQUS_2.sensor_offsets = sensor_offsets;

% 【关键】真实模量值 - 用于计算反演精度
ABAQUS_2.true_modulus.surface = 3500;   % MPa
ABAQUS_2.true_modulus.base = 900;      % MPa
ABAQUS_2.true_modulus.subbase = 325;   % MPa
ABAQUS_2.true_modulus.subgrade = 80;  % MPa

% 土基模量初始值
ABAQUS_2.subgrade_modulus = 80;
ABAQUS_2.boundary_type = 'standard';

test_cases.ABAQUS_2 = ABAQUS_2;
fprintf('  ✓ ABAQUS_02 (薄沥青层): D0=0.3598mm, 真值=[3500,900,325,80]MPa\n');

% -------------------- Case 3: 薄沥青层 --------------------
ABAQUS_3 = struct();
ABAQUS_3.name = 'ABAQUS_3';
ABAQUS_3.description = '薄沥青层 - ABAQUS仿真Case3';
ABAQUS_3.structure_type = 'ThinAC';
ABAQUS_3.structure_type_cn = '薄沥青层';

% 结构参数
ABAQUS_3.pavement_type = 'flexible';
ABAQUS_3.pavement_type_name = '柔性路面';  % [Fix] 补充llmSelectBestSolution所需字段
ABAQUS_3.thickness = [10; 25; 25];  % [AC, BC, SB] cm
ABAQUS_3.poisson = [0.35; 0.35; 0.35];

% 荷载参数 (标准FWD)
ABAQUS_3.load_pressure = 0.7;  % MPa
ABAQUS_3.load_radius = 15;     % cm

% 弯沉数据 (mm) - ABAQUS计算结果
ABAQUS_3.measured_deflection = 0.2524;
ABAQUS_3.deflection_basin = [0.2524, 0.2004, 0.1740, 0.1277, 0.0981, 0.0762, 0.0596];
ABAQUS_3.sensor_offsets = sensor_offsets;

% 【关键】真实模量值 - 用于计算反演精度
ABAQUS_3.true_modulus.surface = 5000;   % MPa
ABAQUS_3.true_modulus.base = 1200;      % MPa
ABAQUS_3.true_modulus.subbase = 450;   % MPa
ABAQUS_3.true_modulus.subgrade = 120;  % MPa

% 土基模量初始值
ABAQUS_3.subgrade_modulus = 120;
ABAQUS_3.boundary_type = 'standard';

test_cases.ABAQUS_3 = ABAQUS_3;
fprintf('  ✓ ABAQUS_03 (薄沥青层): D0=0.2524mm, 真值=[5000,1200,450,120]MPa\n');

% -------------------- Case 4: 标准结构 --------------------
ABAQUS_4 = struct();
ABAQUS_4.name = 'ABAQUS_4';
ABAQUS_4.description = '标准结构 - ABAQUS仿真Case4';
ABAQUS_4.structure_type = 'Standard';
ABAQUS_4.structure_type_cn = '标准结构';

% 结构参数
ABAQUS_4.pavement_type = 'flexible';
ABAQUS_4.pavement_type_name = '柔性路面';  % [Fix] 补充llmSelectBestSolution所需字段
ABAQUS_4.thickness = [15; 20; 30];  % [AC, BC, SB] cm
ABAQUS_4.poisson = [0.35; 0.35; 0.35];

% 荷载参数 (标准FWD)
ABAQUS_4.load_pressure = 0.7;  % MPa
ABAQUS_4.load_radius = 15;     % cm

% 弯沉数据 (mm) - ABAQUS计算结果
ABAQUS_4.measured_deflection = 0.4633;
ABAQUS_4.deflection_basin = [0.4633, 0.3892, 0.3515, 0.2731, 0.2178, 0.1746, 0.1403];
ABAQUS_4.sensor_offsets = sensor_offsets;

% 【关键】真实模量值 - 用于计算反演精度
ABAQUS_4.true_modulus.surface = 2500;   % MPa
ABAQUS_4.true_modulus.base = 700;      % MPa
ABAQUS_4.true_modulus.subbase = 250;   % MPa
ABAQUS_4.true_modulus.subgrade = 50;  % MPa

% 土基模量初始值
ABAQUS_4.subgrade_modulus = 50;
ABAQUS_4.boundary_type = 'standard';

test_cases.ABAQUS_4 = ABAQUS_4;
fprintf('  ✓ ABAQUS_04 (标准结构): D0=0.4633mm, 真值=[2500,700,250,50]MPa\n');

% -------------------- Case 5: 标准结构 --------------------
ABAQUS_5 = struct();
ABAQUS_5.name = 'ABAQUS_5';
ABAQUS_5.description = '标准结构 - ABAQUS仿真Case5';
ABAQUS_5.structure_type = 'Standard';
ABAQUS_5.structure_type_cn = '标准结构';

% 结构参数
ABAQUS_5.pavement_type = 'flexible';
ABAQUS_5.pavement_type_name = '柔性路面';  % [Fix] 补充llmSelectBestSolution所需字段
ABAQUS_5.thickness = [15; 20; 30];  % [AC, BC, SB] cm
ABAQUS_5.poisson = [0.35; 0.35; 0.35];

% 荷载参数 (标准FWD)
ABAQUS_5.load_pressure = 0.7;  % MPa
ABAQUS_5.load_radius = 15;     % cm

% 弯沉数据 (mm) - ABAQUS计算结果
ABAQUS_5.measured_deflection = 0.2676;
ABAQUS_5.deflection_basin = [0.2676, 0.2206, 0.1965, 0.1474, 0.1144, 0.0897, 0.0708];
ABAQUS_5.sensor_offsets = sensor_offsets;

% 【关键】真实模量值 - 用于计算反演精度
ABAQUS_5.true_modulus.surface = 4000;   % MPa
ABAQUS_5.true_modulus.base = 1050;      % MPa
ABAQUS_5.true_modulus.subbase = 375;   % MPa
ABAQUS_5.true_modulus.subgrade = 100;  % MPa

% 土基模量初始值
ABAQUS_5.subgrade_modulus = 100;
ABAQUS_5.boundary_type = 'standard';

test_cases.ABAQUS_5 = ABAQUS_5;
fprintf('  ✓ ABAQUS_05 (标准结构): D0=0.2676mm, 真值=[4000,1050,375,100]MPa\n');

% -------------------- Case 6: 标准结构 --------------------
ABAQUS_6 = struct();
ABAQUS_6.name = 'ABAQUS_6';
ABAQUS_6.description = '标准结构 - ABAQUS仿真Case6';
ABAQUS_6.structure_type = 'Standard';
ABAQUS_6.structure_type_cn = '标准结构';

% 结构参数
ABAQUS_6.pavement_type = 'flexible';
ABAQUS_6.pavement_type_name = '柔性路面';  % [Fix] 补充llmSelectBestSolution所需字段
ABAQUS_6.thickness = [15; 20; 30];  % [AC, BC, SB] cm
ABAQUS_6.poisson = [0.35; 0.35; 0.35];

% 荷载参数 (标准FWD)
ABAQUS_6.load_pressure = 0.7;  % MPa
ABAQUS_6.load_radius = 15;     % cm

% 弯沉数据 (mm) - ABAQUS计算结果
ABAQUS_6.measured_deflection = 0.1894;
ABAQUS_6.deflection_basin = [0.1894, 0.1549, 0.1372, 0.1013, 0.0777, 0.0604, 0.0473];
ABAQUS_6.sensor_offsets = sensor_offsets;

% 【关键】真实模量值 - 用于计算反演精度
ABAQUS_6.true_modulus.surface = 5500;   % MPa
ABAQUS_6.true_modulus.base = 1400;      % MPa
ABAQUS_6.true_modulus.subbase = 500;   % MPa
ABAQUS_6.true_modulus.subgrade = 150;  % MPa

% 土基模量初始值
ABAQUS_6.subgrade_modulus = 150;
ABAQUS_6.boundary_type = 'standard';

test_cases.ABAQUS_6 = ABAQUS_6;
fprintf('  ✓ ABAQUS_06 (标准结构): D0=0.1894mm, 真值=[5500,1400,500,150]MPa\n');

% -------------------- Case 7: 厚沥青层 --------------------
ABAQUS_7 = struct();
ABAQUS_7.name = 'ABAQUS_7';
ABAQUS_7.description = '厚沥青层 - ABAQUS仿真Case7';
ABAQUS_7.structure_type = 'ThickAC';
ABAQUS_7.structure_type_cn = '厚沥青层';

% 结构参数
ABAQUS_7.pavement_type = 'flexible';
ABAQUS_7.pavement_type_name = '柔性路面';  % [Fix] 补充llmSelectBestSolution所需字段
ABAQUS_7.thickness = [20; 25; 30];  % [AC, BC, SB] cm
ABAQUS_7.poisson = [0.35; 0.35; 0.35];

% 荷载参数 (标准FWD)
ABAQUS_7.load_pressure = 0.7;  % MPa
ABAQUS_7.load_radius = 15;     % cm

% 弯沉数据 (mm) - ABAQUS计算结果
ABAQUS_7.measured_deflection = 0.6093;
ABAQUS_7.deflection_basin = [0.6093, 0.5202, 0.4729, 0.3609, 0.2805, 0.2205, 0.1748];
ABAQUS_7.sensor_offsets = sensor_offsets;

% 【关键】真实模量值 - 用于计算反演精度
ABAQUS_7.true_modulus.surface = 2000;   % MPa
ABAQUS_7.true_modulus.base = 250;      % MPa
ABAQUS_7.true_modulus.subbase = 100;   % MPa
ABAQUS_7.true_modulus.subgrade = 40;  % MPa

% 土基模量初始值
ABAQUS_7.subgrade_modulus = 40;
ABAQUS_7.boundary_type = 'standard';

test_cases.ABAQUS_7 = ABAQUS_7;
fprintf('  ✓ ABAQUS_07 (厚沥青层): D0=0.6093mm, 真值=[2000,250,100,40]MPa\n');

% -------------------- Case 8: 厚沥青层 --------------------
ABAQUS_8 = struct();
ABAQUS_8.name = 'ABAQUS_8';
ABAQUS_8.description = '厚沥青层 - ABAQUS仿真Case8';
ABAQUS_8.structure_type = 'ThickAC';
ABAQUS_8.structure_type_cn = '厚沥青层';

% 结构参数
ABAQUS_8.pavement_type = 'flexible';
ABAQUS_8.pavement_type_name = '柔性路面';  % [Fix] 补充llmSelectBestSolution所需字段
ABAQUS_8.thickness = [20; 25; 30];  % [AC, BC, SB] cm
ABAQUS_8.poisson = [0.35; 0.35; 0.35];

% 荷载参数 (标准FWD)
ABAQUS_8.load_pressure = 0.7;  % MPa
ABAQUS_8.load_radius = 15;     % cm

% 弯沉数据 (mm) - ABAQUS计算结果
ABAQUS_8.measured_deflection = 0.3498;
ABAQUS_8.deflection_basin = [0.3498, 0.2961, 0.2681, 0.2035, 0.1582, 0.1248, 0.0992];
ABAQUS_8.sensor_offsets = sensor_offsets;

% 【关键】真实模量值 - 用于计算反演精度
ABAQUS_8.true_modulus.surface = 3250;   % MPa
ABAQUS_8.true_modulus.base = 425;      % MPa
ABAQUS_8.true_modulus.subbase = 200;   % MPa
ABAQUS_8.true_modulus.subgrade = 70;  % MPa

% 土基模量初始值
ABAQUS_8.subgrade_modulus = 70;
ABAQUS_8.boundary_type = 'standard';

test_cases.ABAQUS_8 = ABAQUS_8;
fprintf('  ✓ ABAQUS_08 (厚沥青层): D0=0.3498mm, 真值=[3250,425,200,70]MPa\n');

% -------------------- Case 9: 厚沥青层 --------------------
ABAQUS_9 = struct();
ABAQUS_9.name = 'ABAQUS_9';
ABAQUS_9.description = '厚沥青层 - ABAQUS仿真Case9';
ABAQUS_9.structure_type = 'ThickAC';
ABAQUS_9.structure_type_cn = '厚沥青层';

% 结构参数
ABAQUS_9.pavement_type = 'flexible';
ABAQUS_9.pavement_type_name = '柔性路面';  % [Fix] 补充llmSelectBestSolution所需字段
ABAQUS_9.thickness = [20; 25; 30];  % [AC, BC, SB] cm
ABAQUS_9.poisson = [0.35; 0.35; 0.35];

% 荷载参数 (标准FWD)
ABAQUS_9.load_pressure = 0.7;  % MPa
ABAQUS_9.load_radius = 15;     % cm

% 弯沉数据 (mm) - ABAQUS计算结果
ABAQUS_9.measured_deflection = 0.2456;
ABAQUS_9.deflection_basin = [0.2456, 0.2071, 0.1872, 0.1418, 0.1103, 0.0870, 0.0693];
ABAQUS_9.sensor_offsets = sensor_offsets;

% 【关键】真实模量值 - 用于计算反演精度
ABAQUS_9.true_modulus.surface = 4500;   % MPa
ABAQUS_9.true_modulus.base = 600;      % MPa
ABAQUS_9.true_modulus.subbase = 300;   % MPa
ABAQUS_9.true_modulus.subgrade = 100;  % MPa

% 土基模量初始值
ABAQUS_9.subgrade_modulus = 100;
ABAQUS_9.boundary_type = 'standard';

test_cases.ABAQUS_9 = ABAQUS_9;
fprintf('  ✓ ABAQUS_09 (厚沥青层): D0=0.2456mm, 真值=[4500,600,300,100]MPa\n');

% -------------------- Case 10: 全厚式 --------------------
ABAQUS_10 = struct();
ABAQUS_10.name = 'ABAQUS_10';
ABAQUS_10.description = '全厚式 - ABAQUS仿真Case10';
ABAQUS_10.structure_type = 'FullDepth';
ABAQUS_10.structure_type_cn = '全厚式';

% 结构参数
ABAQUS_10.pavement_type = 'flexible';
ABAQUS_10.pavement_type_name = '柔性路面';  % [Fix] 补充llmSelectBestSolution所需字段
ABAQUS_10.thickness = [25; 35; 20];  % [AC, BC, SB] cm
ABAQUS_10.poisson = [0.35; 0.35; 0.35];

% 荷载参数 (标准FWD)
ABAQUS_10.load_pressure = 0.7;  % MPa
ABAQUS_10.load_radius = 15;     % cm

% 弯沉数据 (mm) - ABAQUS计算结果
ABAQUS_10.measured_deflection = 0.5923;
ABAQUS_10.deflection_basin = [0.5923, 0.5096, 0.4701, 0.3746, 0.3006, 0.2424, 0.1962];
ABAQUS_10.sensor_offsets = sensor_offsets;

% 【关键】真实模量值 - 用于计算反演精度
ABAQUS_10.true_modulus.surface = 1800;   % MPa
ABAQUS_10.true_modulus.base = 200;      % MPa
ABAQUS_10.true_modulus.subbase = 80;   % MPa
ABAQUS_10.true_modulus.subgrade = 35;  % MPa

% 土基模量初始值
ABAQUS_10.subgrade_modulus = 35;
ABAQUS_10.boundary_type = 'standard';

test_cases.ABAQUS_10 = ABAQUS_10;
fprintf('  ✓ ABAQUS_10 (全厚式): D0=0.5923mm, 真值=[1800,200,80,35]MPa\n');

% -------------------- Case 11: 全厚式 --------------------
ABAQUS_11 = struct();
ABAQUS_11.name = 'ABAQUS_11';
ABAQUS_11.description = '全厚式 - ABAQUS仿真Case11';
ABAQUS_11.structure_type = 'FullDepth';
ABAQUS_11.structure_type_cn = '全厚式';

% 结构参数
ABAQUS_11.pavement_type = 'flexible';
ABAQUS_11.pavement_type_name = '柔性路面';  % [Fix] 补充llmSelectBestSolution所需字段
ABAQUS_11.thickness = [25; 35; 20];  % [AC, BC, SB] cm
ABAQUS_11.poisson = [0.35; 0.35; 0.35];

% 荷载参数 (标准FWD)
ABAQUS_11.load_pressure = 0.7;  % MPa
ABAQUS_11.load_radius = 15;     % cm

% 弯沉数据 (mm) - ABAQUS计算结果
ABAQUS_11.measured_deflection = 0.3402;
ABAQUS_11.deflection_basin = [0.3402, 0.2898, 0.2662, 0.2107, 0.1686, 0.1360, 0.1101];
ABAQUS_11.sensor_offsets = sensor_offsets;

% 【关键】真实模量值 - 用于计算反演精度
ABAQUS_11.true_modulus.surface = 2900;   % MPa
ABAQUS_11.true_modulus.base = 350;      % MPa
ABAQUS_11.true_modulus.subbase = 165;   % MPa
ABAQUS_11.true_modulus.subgrade = 62;  % MPa

% 土基模量初始值
ABAQUS_11.subgrade_modulus = 62;
ABAQUS_11.boundary_type = 'standard';

test_cases.ABAQUS_11 = ABAQUS_11;
fprintf('  ✓ ABAQUS_11 (全厚式): D0=0.3402mm, 真值=[2900,350,165,62]MPa\n');

% -------------------- Case 12: 全厚式 --------------------
ABAQUS_12 = struct();
ABAQUS_12.name = 'ABAQUS_12';
ABAQUS_12.description = '全厚式 - ABAQUS仿真Case12';
ABAQUS_12.structure_type = 'FullDepth';
ABAQUS_12.structure_type_cn = '全厚式';

% 结构参数
ABAQUS_12.pavement_type = 'flexible';
ABAQUS_12.pavement_type_name = '柔性路面';  % [Fix] 补充llmSelectBestSolution所需字段
ABAQUS_12.thickness = [25; 35; 20];  % [AC, BC, SB] cm
ABAQUS_12.poisson = [0.35; 0.35; 0.35];

% 荷载参数 (标准FWD)
ABAQUS_12.load_pressure = 0.7;  % MPa
ABAQUS_12.load_radius = 15;     % cm

% 弯沉数据 (mm) - ABAQUS计算结果
ABAQUS_12.measured_deflection = 0.2377;
ABAQUS_12.deflection_basin = [0.2377, 0.2014, 0.1846, 0.1455, 0.1163, 0.0937, 0.0758];
ABAQUS_12.sensor_offsets = sensor_offsets;

% 【关键】真实模量值 - 用于计算反演精度
ABAQUS_12.true_modulus.surface = 4000;   % MPa
ABAQUS_12.true_modulus.base = 500;      % MPa
ABAQUS_12.true_modulus.subbase = 250;   % MPa
ABAQUS_12.true_modulus.subgrade = 90;  % MPa

% 土基模量初始值
ABAQUS_12.subgrade_modulus = 90;
ABAQUS_12.boundary_type = 'standard';

test_cases.ABAQUS_12 = ABAQUS_12;
fprintf('  ✓ ABAQUS_12 (全厚式): D0=0.2377mm, 真值=[4000,500,250,90]MPa\n');

% -------------------- Case 13: 薄面层 --------------------
ABAQUS_13 = struct();
ABAQUS_13.name = 'ABAQUS_13';
ABAQUS_13.description = '薄面层 - ABAQUS仿真Case13';
ABAQUS_13.structure_type = 'ThinSurf';
ABAQUS_13.structure_type_cn = '薄面层';

% 结构参数
ABAQUS_13.pavement_type = 'flexible';
ABAQUS_13.pavement_type_name = '柔性路面';  % [Fix] 补充llmSelectBestSolution所需字段
ABAQUS_13.thickness = [8; 30; 30];  % [AC, BC, SB] cm
ABAQUS_13.poisson = [0.35; 0.35; 0.35];

% 荷载参数 (标准FWD)
ABAQUS_13.load_pressure = 0.7;  % MPa
ABAQUS_13.load_radius = 15;     % cm

% 弯沉数据 (mm) - ABAQUS计算结果
ABAQUS_13.measured_deflection = 1.0799;
ABAQUS_13.deflection_basin = [1.0799, 0.8572, 0.7255, 0.5043, 0.3817, 0.2958, 0.2322];
ABAQUS_13.sensor_offsets = sensor_offsets;

% 【关键】真实模量值 - 用于计算反演精度
ABAQUS_13.true_modulus.surface = 2500;   % MPa
ABAQUS_13.true_modulus.base = 200;      % MPa
ABAQUS_13.true_modulus.subbase = 80;   % MPa
ABAQUS_13.true_modulus.subgrade = 30;  % MPa

% 土基模量初始值
ABAQUS_13.subgrade_modulus = 30;
ABAQUS_13.boundary_type = 'standard';

test_cases.ABAQUS_13 = ABAQUS_13;
fprintf('  ✓ ABAQUS_13 (薄面层): D0=1.0799mm, 真值=[2500,200,80,30]MPa\n');

% -------------------- Case 14: 薄面层 --------------------
ABAQUS_14 = struct();
ABAQUS_14.name = 'ABAQUS_14';
ABAQUS_14.description = '薄面层 - ABAQUS仿真Case14';
ABAQUS_14.structure_type = 'ThinSurf';
ABAQUS_14.structure_type_cn = '薄面层';

% 结构参数
ABAQUS_14.pavement_type = 'flexible';
ABAQUS_14.pavement_type_name = '柔性路面';  % [Fix] 补充llmSelectBestSolution所需字段
ABAQUS_14.thickness = [8; 30; 30];  % [AC, BC, SB] cm
ABAQUS_14.poisson = [0.35; 0.35; 0.35];

% 荷载参数 (标准FWD)
ABAQUS_14.load_pressure = 0.7;  % MPa
ABAQUS_14.load_radius = 15;     % cm

% 弯沉数据 (mm) - ABAQUS计算结果
ABAQUS_14.measured_deflection = 0.5939;
ABAQUS_14.deflection_basin = [0.5939, 0.4666, 0.3923, 0.2714, 0.2061, 0.1603, 0.1263];
ABAQUS_14.sensor_offsets = sensor_offsets;

% 【关键】真实模量值 - 用于计算反演精度
ABAQUS_14.true_modulus.surface = 4250;   % MPa
ABAQUS_14.true_modulus.base = 350;      % MPa
ABAQUS_14.true_modulus.subbase = 165;   % MPa
ABAQUS_14.true_modulus.subgrade = 55;  % MPa

% 土基模量初始值
ABAQUS_14.subgrade_modulus = 55;
ABAQUS_14.boundary_type = 'standard';

test_cases.ABAQUS_14 = ABAQUS_14;
fprintf('  ✓ ABAQUS_14 (薄面层): D0=0.5939mm, 真值=[4250,350,165,55]MPa\n');

% -------------------- Case 15: 薄面层 --------------------
ABAQUS_15 = struct();
ABAQUS_15.name = 'ABAQUS_15';
ABAQUS_15.description = '薄面层 - ABAQUS仿真Case15';
ABAQUS_15.structure_type = 'ThinSurf';
ABAQUS_15.structure_type_cn = '薄面层';

% 结构参数
ABAQUS_15.pavement_type = 'flexible';
ABAQUS_15.pavement_type_name = '柔性路面';  % [Fix] 补充llmSelectBestSolution所需字段
ABAQUS_15.thickness = [8; 30; 30];  % [AC, BC, SB] cm
ABAQUS_15.poisson = [0.35; 0.35; 0.35];

% 荷载参数 (标准FWD)
ABAQUS_15.load_pressure = 0.7;  % MPa
ABAQUS_15.load_radius = 15;     % cm

% 弯沉数据 (mm) - ABAQUS计算结果
ABAQUS_15.measured_deflection = 0.4100;
ABAQUS_15.deflection_basin = [0.4100, 0.3208, 0.2691, 0.1858, 0.1412, 0.1100, 0.0867];
ABAQUS_15.sensor_offsets = sensor_offsets;

% 【关键】真实模量值 - 用于计算反演精度
ABAQUS_15.true_modulus.surface = 6000;   % MPa
ABAQUS_15.true_modulus.base = 500;      % MPa
ABAQUS_15.true_modulus.subbase = 250;   % MPa
ABAQUS_15.true_modulus.subgrade = 80;  % MPa

% 土基模量初始值
ABAQUS_15.subgrade_modulus = 80;
ABAQUS_15.boundary_type = 'standard';

test_cases.ABAQUS_15 = ABAQUS_15;
fprintf('  ✓ ABAQUS_15 (薄面层): D0=0.4100mm, 真值=[6000,500,250,80]MPa\n');


%% ════════════════════════════════════════════════════════════════════
%  足尺环道实测数据 - 5组半刚性结构（无真值，用于通用性验证）
%  数据来源: 足尺环道FWD实测（已筛选优质数据）
%  结构类型: 标准半刚性基层结构（水泥稳定碎石基层 + 水泥土底基层）
%  筛选标准: D20/D0>85%, D20-D30突变<20%, 弯沉盆单调递减
%  v6.2.0更新: 使用STR2,STR3,STR4,STR6,STR7替换原数据
%% ════════════════════════════════════════════════════════════════════

fprintf('\n加载 足尺环道 实测数据 (5组半刚性结构 - 优质筛选)...\n\n');

% -------------------- RingRoad_1: STR2 (AC=12cm) --------------------
% [Fix1] load_pressure: CSV原值7.2433e-1→0.724332 MPa（原代码0.7243正确，精度补全）
% [Fix2] sensor_offsets: RIOH实际偏移[0,23,53,69,85,116,153]cm（原[0,20,30,60,90,120,150]错误）
RingRoad_1 = struct();
RingRoad_1.name = 'RingRoad_1';
RingRoad_1.description = 'STR2 - 标准半刚性 (CBG-A×2+CS) (AC=12cm)';
RingRoad_1.structure_type = 'SemiRigid';
RingRoad_1.structure_type_cn = '半刚性基层';
RingRoad_1.pavement_type = 'semi_rigid';
RingRoad_1.pavement_type_name = '半刚性基层路面';  % [Fix] 补充llmSelectBestSolution所需字段
RingRoad_1.station = 'ZK0+160';

% 结构参数
% 沥青层: 12cm
% 基层: CBG-A(20cm)+CBG-A(20cm)=40cm (水泥稳定碎石)
% 底基层: CS(20cm) (水泥土)
RingRoad_1.thickness = [12; 40; 20];  % [AC, BC, SB] cm
RingRoad_1.poisson = [0.35; 0.25; 0.30];

% 荷载参数
% [Fix1] 精确值：51.20kN / (π×0.15²×1000) = 0.724332 MPa
RingRoad_1.load_pressure = 0.724332;  % MPa
RingRoad_1.load_radius = 15;          % cm

% 弯沉数据 (mm) - FWD实测 (筛选后优质数据, D20/D0=89.7%)
RingRoad_1.measured_deflection = 0.0640;
RingRoad_1.deflection_basin = [0.0640, 0.0574, 0.0522, 0.0453, 0.0355, 0.0282, 0.0260];
% [Fix2] RIOH环道实际传感器位置（来源：RIOHTRACK_structure_params.csv）
RingRoad_1.sensor_offsets = [0, 23, 53, 69, 85, 116, 153];  % cm

% 无真值 - 实测数据
RingRoad_1.has_true_modulus = false;

% 土基模量估计值
RingRoad_1.subgrade_modulus = 80;  % MPa
RingRoad_1.boundary_type = 'standard';

% 环境信息
RingRoad_1.road_temp = 8.7;   % 路面温度 ℃
RingRoad_1.air_temp = 11.0;   % 空气温度 ℃

test_cases.RingRoad_1 = RingRoad_1;
fprintf('  ✓ RingRoad_1 (STR2, AC=12cm): D0=0.0640mm, 半刚性基层\n');

% -------------------- RingRoad_2: STR3 (AC=12cm) --------------------
% [Fix3] AC=12cm（原误用14cm；RIOHTRACK_structure_params: STR3 thickness_AC_cm=12）
% [Fix2] sensor_offsets: RIOH实际偏移[0,23,53,69,85,116,153]cm
RingRoad_2 = struct();
RingRoad_2.name = 'RingRoad_2';
RingRoad_2.description = 'STR3 - 标准半刚性 (CBG-A+CS) (AC=12cm)';
RingRoad_2.structure_type = 'SemiRigid';
RingRoad_2.structure_type_cn = '半刚性基层';
RingRoad_2.pavement_type = 'semi_rigid';
RingRoad_2.pavement_type_name = '半刚性基层路面';  % [Fix] 补充llmSelectBestSolution所需字段
RingRoad_2.station = 'ZK0+090';

% 结构参数
% [Fix3] AC=12cm（设计值），BC=40cm CBG-A，SB=20cm CS
RingRoad_2.thickness = [12; 40; 20];  % [AC, BC, SB] cm
RingRoad_2.poisson = [0.35; 0.25; 0.30];

% 荷载参数
RingRoad_2.load_pressure = 0.723907;  % MPa (51.17kN / π×0.15²×1000)
RingRoad_2.load_radius = 15;          % cm

% 弯沉数据 (mm) - FWD实测 (D20/D0=98.8%, 近场弯沉平缓)
RingRoad_2.measured_deflection = 0.0849;
RingRoad_2.deflection_basin = [0.0849, 0.0839, 0.0691, 0.0570, 0.0472, 0.0373, 0.0316];
% [Fix2] RIOH实际传感器位置
RingRoad_2.sensor_offsets = [0, 23, 53, 69, 85, 116, 153];  % cm

% 无真值 - 实测数据
RingRoad_2.has_true_modulus = false;

% 土基模量估计值
RingRoad_2.subgrade_modulus = 80;  % MPa
RingRoad_2.boundary_type = 'standard';

% 环境信息
RingRoad_2.road_temp = 9.3;
RingRoad_2.air_temp = 11.3;

test_cases.RingRoad_2 = RingRoad_2;
fprintf('  ✓ RingRoad_2 (STR3, AC=12cm): D0=0.0849mm, 半刚性基层\n');

% -------------------- RingRoad_3: STR4 (AC=12cm, LCC基层) --------------------
% [Fix3] AC=12cm（原误用14cm；RIOHTRACK_structure_params: STR4 thickness_AC_cm=12）
% [Fix4] BC=24cm LCC（原误用BC=40cm CBG-A；STR4基层实际为LCC低剂量水泥稳定碎石24cm）
% [Fix2] sensor_offsets: RIOH实际偏移[0,23,53,69,85,116,153]cm
RingRoad_3 = struct();
RingRoad_3.name = 'RingRoad_3';
RingRoad_3.description = 'STR4 - 半刚性 (LCC基层+CBG-A底基层) (AC=12cm)';
RingRoad_3.structure_type = 'SemiRigid';
RingRoad_3.structure_type_cn = '半刚性基层';
RingRoad_3.pavement_type = 'semi_rigid';
RingRoad_3.pavement_type_name = '半刚性基层路面';  % [Fix] 补充llmSelectBestSolution所需字段
RingRoad_3.station = 'ZK0+780';

% 结构参数
% [Fix3] AC=12cm，[Fix4] BC=24cm (LCC低剂量水泥碎石)，SB=40cm (CBG-A+CS)
RingRoad_3.thickness = [12; 24; 40];  % [AC, BC, SB] cm
RingRoad_3.poisson = [0.35; 0.25; 0.25];

% 荷载参数
RingRoad_3.load_pressure = 0.725322;  % MPa (51.27kN / π×0.15²×1000)
RingRoad_3.load_radius = 15;          % cm

% 弯沉数据 (mm) - FWD实测 (D20/D0=85.7%, 符合正常衰减规律)
RingRoad_3.measured_deflection = 0.0505;
RingRoad_3.deflection_basin = [0.0505, 0.0433, 0.0372, 0.0336, 0.0284, 0.0274, 0.0253];
% [Fix2] RIOH实际传感器位置
RingRoad_3.sensor_offsets = [0, 23, 53, 69, 85, 116, 153];  % cm

% 无真值 - 实测数据
RingRoad_3.has_true_modulus = false;

% 土基模量估计值
RingRoad_3.subgrade_modulus = 80;  % MPa
RingRoad_3.boundary_type = 'standard';

% 环境信息
RingRoad_3.road_temp = 9.0;
RingRoad_3.air_temp = 9.4;

test_cases.RingRoad_3 = RingRoad_3;
fprintf('  ✓ RingRoad_3 (STR4, AC=12cm, LCC基层24cm): D0=0.0505mm, 半刚性基层\n');

% -------------------- RingRoad_4: STR6 (AC=16cm) --------------------
% [Fix1] load_pressure精确值0.717824 MPa（原0.7178精度不足）
% [Fix2] sensor_offsets: RIOH实际偏移[0,23,53,69,85,116,153]cm
RingRoad_4 = struct();
RingRoad_4.name = 'RingRoad_4';
RingRoad_4.description = 'STR6 - 中厚沥青半刚性 (CBG-A+CS) (AC=16cm)';
RingRoad_4.structure_type = 'SemiRigid';
RingRoad_4.structure_type_cn = '半刚性基层';
RingRoad_4.pavement_type = 'semi_rigid';
RingRoad_4.pavement_type_name = '半刚性基层路面';  % [Fix] 补充llmSelectBestSolution所需字段
RingRoad_4.station = 'ZK0+830';

% 结构参数
RingRoad_4.thickness = [16; 40; 20];  % [AC, BC, SB] cm
RingRoad_4.poisson = [0.35; 0.25; 0.30];

% 荷载参数
% [Fix1] 精确值：50.76kN / (π×0.15²×1000) = 0.717824 MPa
RingRoad_4.load_pressure = 0.717824;  % MPa
RingRoad_4.load_radius = 15;          % cm

% 弯沉数据 (mm) - FWD实测 (D20/D0=96.1%, 弯沉盆形状优秀)
RingRoad_4.measured_deflection = 0.0514;
RingRoad_4.deflection_basin = [0.0514, 0.0494, 0.0434, 0.0366, 0.0356, 0.0346, 0.0336];
% [Fix2] RIOH实际传感器位置
RingRoad_4.sensor_offsets = [0, 23, 53, 69, 85, 116, 153];  % cm

% 无真值 - 实测数据
RingRoad_4.has_true_modulus = false;

% 土基模量估计值
RingRoad_4.subgrade_modulus = 80;  % MPa
RingRoad_4.boundary_type = 'standard';

% 环境信息
RingRoad_4.road_temp = 12.3;
RingRoad_4.air_temp = 14.3;

test_cases.RingRoad_4 = RingRoad_4;
fprintf('  ✓ RingRoad_4 (STR6, AC=16cm): D0=0.0514mm, 半刚性基层\n');

% -------------------- RingRoad_5: STR7 (AC=18cm) --------------------
% [Fix1] load_pressure精确值0.720654 MPa（原0.7207精度不足）
% [Fix2] sensor_offsets: RIOH实际偏移[0,23,53,69,85,116,153]cm
RingRoad_5 = struct();
RingRoad_5.name = 'RingRoad_5';
RingRoad_5.description = 'STR7 - 中厚沥青半刚性 (CBG-A+CS) (AC=18cm)';
RingRoad_5.structure_type = 'SemiRigid';
RingRoad_5.structure_type_cn = '半刚性基层';
RingRoad_5.pavement_type = 'semi_rigid';
RingRoad_5.pavement_type_name = '半刚性基层路面';  % [Fix] 补充llmSelectBestSolution所需字段
RingRoad_5.station = 'ZK0+880';

% 结构参数
RingRoad_5.thickness = [18; 40; 20];  % [AC, BC, SB] cm
RingRoad_5.poisson = [0.35; 0.25; 0.30];

% 荷载参数
% [Fix1] 精确值：50.97kN / (π×0.15²×1000) = 0.720654 MPa
RingRoad_5.load_pressure = 0.720654;  % MPa
RingRoad_5.load_radius = 15;          % cm

% 弯沉数据 (mm) - FWD实测 (D20/D0=85.7%, 符合正常衰减规律)
RingRoad_5.measured_deflection = 0.0532;
RingRoad_5.deflection_basin = [0.0532, 0.0456, 0.0370, 0.0353, 0.0343, 0.0333, 0.0323];
% [Fix2] RIOH实际传感器位置
RingRoad_5.sensor_offsets = [0, 23, 53, 69, 85, 116, 153];  % cm

% 无真值 - 实测数据
RingRoad_5.has_true_modulus = false;

% 土基模量估计值
RingRoad_5.subgrade_modulus = 80;  % MPa
RingRoad_5.boundary_type = 'standard';

% 环境信息
RingRoad_5.road_temp = 13.7;
RingRoad_5.air_temp = 12.9;

test_cases.RingRoad_5 = RingRoad_5;
fprintf('  ✓ RingRoad_5 (STR7, AC=18cm): D0=0.0532mm, 半刚性基层\n');


%% ==================== 汇总信息 ====================
fprintf('\n');
fprintf('═══════════════════════════════════════════════════════════════\n');
fprintf('  数据加载完成！共 20 组数据 (ABAQUS 15组 + 环道 5组)\n');
fprintf('═══════════════════════════════════════════════════════════════\n');
fprintf('\n');
fprintf('  【ABAQUS仿真数据 - 15组柔性路面（有真值）】\n');
fprintf('  ┌────────────┬────────────┬────────────┬─────────────────────────────────┐\n');
fprintf('  │ Case ID    │ 结构类型   │ D0 (mm)    │ 真实模量 [AC,BC,SB,SG] MPa      │\n');
fprintf('  ├────────────┼────────────┼────────────┼─────────────────────────────────┤\n');
fprintf('  │ ABAQUS_01  │ 薄沥青层   │ 0.6353     │ [ 2000,  600, 200,  40]         │\n');
fprintf('  │ ABAQUS_02  │ 薄沥青层   │ 0.3598     │ [ 3500,  900, 325,  80]         │\n');
fprintf('  │ ABAQUS_03  │ 薄沥青层   │ 0.2524     │ [ 5000, 1200, 450, 120]         │\n');
fprintf('  │ ABAQUS_04  │ 标准结构   │ 0.4633     │ [ 2500,  700, 250,  50]         │\n');
fprintf('  │ ABAQUS_05  │ 标准结构   │ 0.2676     │ [ 4000, 1050, 375, 100]         │\n');
fprintf('  │ ABAQUS_06  │ 标准结构   │ 0.1894     │ [ 5500, 1400, 500, 150]         │\n');
fprintf('  │ ABAQUS_07  │ 厚沥青层   │ 0.6093     │ [ 2000,  250, 100,  40]         │\n');
fprintf('  │ ABAQUS_08  │ 厚沥青层   │ 0.3498     │ [ 3250,  425, 200,  70]         │\n');
fprintf('  │ ABAQUS_09  │ 厚沥青层   │ 0.2456     │ [ 4500,  600, 300, 100]         │\n');
fprintf('  │ ABAQUS_10  │ 全厚式     │ 0.5923     │ [ 1800,  200,  80,  35]         │\n');
fprintf('  │ ABAQUS_11  │ 全厚式     │ 0.3402     │ [ 2900,  350, 165,  62]         │\n');
fprintf('  │ ABAQUS_12  │ 全厚式     │ 0.2377     │ [ 4000,  500, 250,  90]         │\n');
fprintf('  │ ABAQUS_13  │ 薄面层     │ 1.0799     │ [ 2500,  200,  80,  30]         │\n');
fprintf('  │ ABAQUS_14  │ 薄面层     │ 0.5939     │ [ 4250,  350, 165,  55]         │\n');
fprintf('  │ ABAQUS_15  │ 薄面层     │ 0.4100     │ [ 6000,  500, 250,  80]         │\n');
fprintf('  └────────────┴────────────┴────────────┴─────────────────────────────────┘\n');
fprintf('\n');
fprintf('  【足尺环道实测数据 - 5组半刚性结构（无真值，优质筛选）】\n');
fprintf('  ┌────────────┬────────────┬────────────┬─────────────────────────────────┐\n');
fprintf('  │ Case ID    │ 原结构ID   │ D0 (mm)    │ 层厚 [AC,BC,SB] cm              │\n');
fprintf('  ├────────────┼────────────┼────────────┼─────────────────────────────────┤\n');
fprintf('  │ RingRoad_1 │ STR2       │ 0.0640     │ [12, 40, 20] 标准半刚性         │\n');
fprintf('  │ RingRoad_2 │ STR3       │ 0.0849     │ [12, 40, 20] 标准半刚性         │\n');
fprintf('  │ RingRoad_3 │ STR4       │ 0.0505     │ [12, 24, 40] LCC基层半刚性      │\n');
fprintf('  │ RingRoad_4 │ STR6       │ 0.0514     │ [16, 40, 20] 中厚沥青半刚性     │\n');
fprintf('  │ RingRoad_5 │ STR7       │ 0.0532     │ [18, 40, 20] 中厚沥青半刚性     │\n');
fprintf('  └────────────┴────────────┴────────────┴─────────────────────────────────┘\n');
fprintf('\n');
fprintf('  【数据筛选说明】\n');
fprintf('  - 筛选标准: D20/D0>85%%, D20-D30突变<20%%, 弯沉盆单调递减\n');
fprintf('  - 剔除: STR1(突变), STR5(D20偏低), STR8(突变), STR9(D20偏低)\n');
fprintf('  - 保留: STR2, STR3, STR4, STR6, STR7 (弯沉盆形状良好)\n');
fprintf('\n');
fprintf('  【ABAQUS结构类型分布】\n');
fprintf('  - 薄沥青层 (ThinAC):   Case 1-3,  AC=10cm\n');
fprintf('  - 标准结构 (Standard): Case 4-6,  AC=15cm\n');
fprintf('  - 厚沥青层 (ThickAC):  Case 7-9,  AC=20cm\n');
fprintf('  - 全厚式 (FullDepth):  Case 10-12, AC=25cm\n');
fprintf('  - 薄面层 (ThinSurf):   Case 13-15, AC=8cm\n');
fprintf('\n');
fprintf('  【环道结构特点】\n');
fprintf('  - 基层材料: 水泥稳定碎石 (CBG), 模量范围 5000-15000 MPa\n');
fprintf('  - 底基层材料: 水泥土 (CS), 模量范围 1500-5000 MPa\n');
fprintf('  - D0较小(0.05-0.09mm): 半刚性基层刚度高\n');
fprintf('\n');
fprintf('  【使用方法】\n');
fprintf('  runTestCases(''ABAQUS'');       %% 运行ABAQUS全部15组\n');
fprintf('  runTestCases(''ABAQUS_1'');     %% 运行ABAQUS第1组\n');
fprintf('  runTestCases(''RingRoad'');     %% 运行环道全部5组\n');
fprintf('  runTestCases(''RingRoad_1'');   %% 运行环道第1组\n');
fprintf('  runTestCases(''all'');          %% 运行全部20组\n');
fprintf('\n');

end