function response = callLLMAPI(prompt, config, model_type)
% CALLLLMAPI 统一的LLM API调用接口（带日志功能）
% 支持 DeepSeek API 和 OLLAMA (Qwen2.5/Llama3等开源模型)
%
% 输入:
%   prompt     - 提示文本 (字符串)
%   config     - 配置结构体 (从JSON加载)
%   model_type - 模型类型: 'deepseek' 或 'ollama'
%
% 输出:
%   response   - LLM响应文本
%
% 【v5.3.4更新】新增日志功能
%   - 自动保存每次LLM调用的prompt和response到JSON文件
%   - 日志保存位置: output/llm_logs/
%   - 可通过 log_enabled 变量开关
%
% 版本: v5.3.4-with-logging
% 日期: 2025-12

    response = '';
    
    % ═══════════════════════════════════════════════════════════════════
    % 【日志功能配置】
    % ═══════════════════════════════════════════════════════════════════
    log_enabled = true;   % 设为 false 可关闭日志
    log_dir = 'output/llm_logs';
    
    if log_enabled && ~exist(log_dir, 'dir')
        mkdir(log_dir);
        fprintf('    [LOG] 创建日志目录: %s\n', log_dir);
    end
    % ═══════════════════════════════════════════════════════════════════
    
    try
        switch lower(model_type)
            case 'deepseek'
                response = callDeepSeek(prompt, config);
            case 'ollama'
                response = callOllama(prompt, config);
            otherwise
                % 默认使用deepseek（保持向后兼容）
                warning('callLLMAPI:UnknownModel', '未知的模型类型: %s，使用DeepSeek', model_type);
                response = callDeepSeek(prompt, config);
        end
        
        % ═══════════════════════════════════════════════════════════════
        % 【保存日志】
        % ═══════════════════════════════════════════════════════════════
        if log_enabled && ~isempty(response)
            try
                timestamp = datestr(now, 'yyyymmdd_HHMMSS_FFF');
                log_file = fullfile(log_dir, sprintf('llm_call_%s.json', timestamp));
                
                % 构建日志数据
                log_data = struct();
                log_data.timestamp = datestr(now, 'yyyy-mm-dd HH:MM:SS');
                log_data.model = model_type;
                log_data.prompt = prompt;
                log_data.response = response;
                log_data.prompt_length = length(prompt);
                log_data.response_length = length(response);
                
                % 保存为JSON（UTF-8编码）
                json_str = jsonencode(log_data);
                % 格式化JSON（增加可读性）
                json_str = strrep(json_str, ',"', sprintf(',\n  "'));
                json_str = strrep(json_str, '{', sprintf('{\n  '));
                json_str = strrep(json_str, '}', sprintf('\n}'));
                
                fid = fopen(log_file, 'w', 'n', 'UTF-8');
                if fid > 0
                    fprintf(fid, '%s', json_str);
                    fclose(fid);
                    fprintf('    [LOG] 已保存: %s\n', log_file);
                end
            catch log_err
                fprintf('    [LOG] 日志保存失败: %s\n', log_err.message);
            end
        end
        % ═══════════════════════════════════════════════════════════════
        
    catch ME
        warning('callLLMAPI:APIError', 'LLM API调用失败: %s', ME.message);
        response = '';
    end
end

%% ==================== DeepSeek API ====================
function response = callDeepSeek(prompt, config)
% 调用DeepSeek在线API（保持与原版完全兼容）

    response = '';
    
    try
        % 获取配置参数
        api_key = config.deepseek.api_key;
        base_url = config.deepseek.base_url;
        model = config.deepseek.model;
        max_tokens = config.deepseek.max_tokens;
        temperature = config.deepseek.temperature;
        timeout = config.deepseek.timeout;
        
        % 构建请求URL
        url = [base_url, '/chat/completions'];
        
        % 构建请求体
        messages = struct('role', 'user', 'content', prompt);
        request_body = struct();
        request_body.model = model;
        request_body.messages = {messages};
        request_body.max_tokens = max_tokens;
        request_body.temperature = temperature;
        
        json_body = jsonencode(request_body);
        
        % 设置HTTP选项
        options = weboptions(...
            'MediaType', 'application/json', ...
            'HeaderFields', {'Authorization', ['Bearer ', api_key]; ...
                            'Content-Type', 'application/json'}, ...
            'Timeout', timeout, ...
            'RequestMethod', 'post');
        
        % 发送请求
        result = webwrite(url, json_body, options);
        
        % 解析响应
        if isfield(result, 'choices') && ~isempty(result.choices)
            if iscell(result.choices)
                response = result.choices{1}.message.content;
            else
                response = result.choices(1).message.content;
            end
        end
        
    catch ME
        warning('callLLMAPI:DeepSeekError', 'DeepSeek API错误: %s', ME.message);
        response = '';
    end
end

%% ==================== OLLAMA API ====================
function response = callOllama(prompt, config)
% 调用本地OLLAMA服务

    response = '';
    
    % 检查ollama配置是否存在
    if ~isfield(config, 'ollama')
        warning('callLLMAPI:NoOllamaConfig', 'config中缺少ollama配置，请检查配置文件');
        return;
    end
    
    try
        % 获取配置参数
        base_url = config.ollama.base_url;
        model = config.ollama.model;
        temperature = config.ollama.temperature;
        timeout = config.ollama.timeout;
        
        % 构建请求URL - 使用generate端点
        url = [base_url, '/api/generate'];
        
        % 构建请求体
        request_body = struct();
        request_body.model = model;
        request_body.prompt = prompt;
        request_body.stream = false;  % 非流式输出
        
        % OLLAMA的options参数
        options_param = struct();
        options_param.temperature = temperature;
        options_param.num_predict = 2000;  % 相当于max_tokens
        request_body.options = options_param;
        
        json_body = jsonencode(request_body);
        
        % 设置HTTP选项
        options = weboptions(...
            'MediaType', 'application/json', ...
            'ContentType', 'json', ...
            'Timeout', timeout, ...
            'RequestMethod', 'post');
        
        % 发送请求
        result = webwrite(url, json_body, options);
        
        % 解析响应
        if isstruct(result) && isfield(result, 'response')
            response = result.response;
        elseif ischar(result) || isstring(result)
            % 有时返回的是JSON字符串
            try
                decoded = jsondecode(result);
                if isfield(decoded, 'response')
                    response = decoded.response;
                end
            catch
                response = char(result);
            end
        end
        
        % 打印调试信息
        if ~isempty(response)
            fprintf('    [OLLAMA:%s] 响应长度: %d字符\n', model, length(response));
        else
            fprintf('    [OLLAMA:%s] 响应为空\n', model);
        end
        
    catch ME
        % 详细错误处理（使用正确的warning格式）
        warning('callLLMAPI:OllamaError', 'OLLAMA API错误: %s', ME.message);
        
        % 检查常见问题
        if contains(ME.message, 'connection') || contains(ME.message, 'refused') || ...
           contains(ME.message, 'Unable to resolve')
            fprintf('\n    ┌─────────────────────────────────────────┐\n');
            fprintf('    │  OLLAMA连接失败，请检查:                │\n');
            fprintf('    │  1. OLLAMA服务是否运行: ollama serve    │\n');
            fprintf('    │  2. 模型是否已下载: ollama pull %s │\n', config.ollama.model);
            fprintf('    │  3. 端口11434是否被占用                 │\n');
            fprintf('    └─────────────────────────────────────────┘\n\n');
        elseif contains(ME.message, 'timeout') || contains(ME.message, 'Timeout')
            fprintf('    [提示] 请求超时，可能是模型推理较慢，建议增加timeout设置\n');
        end
        
        response = '';
    end
end