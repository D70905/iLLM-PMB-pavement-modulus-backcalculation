function resultText = callRAGService(queryStr, topK)
    % callRAGService - 调用本地 RAG 检索服务获取规范知识
    %
    % MATLAB ↔ RAG 检索服务调用接口
    % 用法（在 buildScoringPrompt 中）:
    %   ragResults = callRAGService('半刚性路面 水泥稳定碎石基层 温度25°C 面层厚18cm', 4);
    %   % 返回字符串，可直接拼入 prompt
    %
    % Input:
    %   queryStr - 查询字符串（描述当前路面结构+材料+工况）
    %   topK     - 返回最相关的 K 条知识（默认 3）
    %
    % Output:
    %   resultText - 格式化的规范条文字符串，含出处，可直接拼入 prompt
    %
    % Example:
    %   txt = callRAGService('水泥稳定碎石基层 半刚性路面 25°C', 3);

    if nargin < 2
        topK = 3;
    end

    % RAG 检索服务地址
    url = 'http://127.0.0.1:8000/retrieve';

    % 构造请求
    options = weboptions('RequestMethod', 'post', ...
                         'MediaType', 'application/json', ...
                         'Timeout', 10);
    data = struct('query', queryStr, 'top_k', topK);

    try
        response = webwrite(url, data, options);

        % 拼接检索结果为 prompt 可用的文本
        resultText = '';
        for i = 1:length(response.knowledge)
            item = response.knowledge(i);
            resultText = [resultText, sprintf(...
                '【%s】%s （出处: %s）\n', ...
                item.id, item.content, item.source)];
        end

    catch ME
        % 检索服务不可用时，返回空（prompt 里仍有静态硬约束兜底）
        warning('RAG service unavailable: %s。将使用静态知识。', ME.message);
        resultText = '';
    end
end
