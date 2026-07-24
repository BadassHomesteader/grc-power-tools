using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace PowerTools.Core;

/// <summary>
/// Optional cloud transcript cleanup — port of CloudPolish.swift. Text-only,
/// user-supplied keys, called only when polish mode is claude/openai.
/// </summary>
public static class CloudPolish
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };

    public static async Task<string?> Claude(string instructions, string prompt, string model, string apiKey)
    {
        var body = new JsonObject
        {
            ["model"] = model,
            ["max_tokens"] = 2048,
            ["system"] = instructions,
            ["messages"] = new JsonArray(new JsonObject
            {
                ["role"] = "user",
                ["content"] = prompt,
            }),
        };
        using var req = new HttpRequestMessage(HttpMethod.Post, "https://api.anthropic.com/v1/messages");
        req.Headers.Add("x-api-key", apiKey);
        req.Headers.Add("anthropic-version", "2023-06-01");
        req.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        using var resp = await Http.SendAsync(req);
        var json = await resp.Content.ReadAsStringAsync();
        if (!resp.IsSuccessStatusCode)
        {
            Logger.Log($"polish: claude HTTP {(int)resp.StatusCode}: {Truncate(json)}");
            return null;
        }
        using var doc = JsonDocument.Parse(json);
        var text = doc.RootElement.GetProperty("content")[0].GetProperty("text").GetString();
        return text?.Trim();
    }

    public static async Task<string?> OpenAI(string instructions, string prompt, string model, string apiKey)
    {
        var body = new JsonObject
        {
            ["model"] = model,
            ["messages"] = new JsonArray(
                new JsonObject { ["role"] = "system", ["content"] = instructions },
                new JsonObject { ["role"] = "user", ["content"] = prompt }),
        };
        using var req = new HttpRequestMessage(HttpMethod.Post, "https://api.openai.com/v1/chat/completions");
        req.Headers.Add("Authorization", $"Bearer {apiKey}");
        req.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        using var resp = await Http.SendAsync(req);
        var json = await resp.Content.ReadAsStringAsync();
        if (!resp.IsSuccessStatusCode)
        {
            Logger.Log($"polish: openai HTTP {(int)resp.StatusCode}: {Truncate(json)}");
            return null;
        }
        using var doc = JsonDocument.Parse(json);
        var text = doc.RootElement.GetProperty("choices")[0].GetProperty("message").GetProperty("content").GetString();
        return text?.Trim();
    }

    /// <summary>
    /// Quick Capture POST — port of postCapture(). Endpoint/header/body are all
    /// user config; %TEXT% in the body template is replaced with the
    /// JSON-escaped capture text.
    /// </summary>
    public static async Task<bool> PostCapture(Config.Connection conn, string text)
    {
        if (string.IsNullOrEmpty(conn.Endpoint)) return false;
        var escaped = JsonSerializer.Serialize(text);           // includes surrounding quotes
        var body = conn.BodyTemplate.Replace("%TEXT%", escaped[1..^1]);
        using var req = new HttpRequestMessage(HttpMethod.Post, conn.Endpoint);
        if (!string.IsNullOrEmpty(conn.AuthHeader) && SecretsStore.Get(conn.TokenAccount) is { } token)
            req.Headers.TryAddWithoutValidation(conn.AuthHeader, token);
        req.Content = new StringContent(body, Encoding.UTF8, "application/json");
        using var resp = await Http.SendAsync(req);
        if (!resp.IsSuccessStatusCode)
            Logger.Log($"capture: {conn.Name} HTTP {(int)resp.StatusCode}");
        return resp.IsSuccessStatusCode;
    }

    private static string Truncate(string s) => s.Length > 200 ? s[..200] : s;
}
