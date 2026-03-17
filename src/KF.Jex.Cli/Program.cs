using System.CommandLine;
using System.Text.Json;
using Newtonsoft.Json.Linq;
using KoreForge.Jex;

namespace KF.Jex.Cli;

/// <summary>
/// JEX CLI - Execute JEX transformation scripts from the command line.
/// </summary>
public class Program
{
    public static async Task<int> Main(string[] args)
    {
        var scriptArg = new Argument<FileInfo>(
            "script",
            "Path to the JEX script file (.jex)");

        var inputOption = new Option<FileInfo?>(
            aliases: ["--input", "-i"],
            description: "Path to input JSON file (defaults to <script>.input.json)");

        var outputOption = new Option<FileInfo?>(
            aliases: ["--output", "-o"],
            description: "Path to write output JSON (defaults to stdout)");

        var metaOption = new Option<FileInfo?>(
            aliases: ["--meta", "-m"],
            description: "Path to metadata JSON file");

        var formatOption = new Option<OutputFormat>(
            aliases: ["--format", "-f"],
            getDefaultValue: () => OutputFormat.Json,
            description: "Output format: Json, Pretty, or Detailed");

        var watchOption = new Option<bool>(
            aliases: ["--watch", "-w"],
            description: "Watch for file changes and re-run automatically");

        var rootCommand = new RootCommand("JEX - JSON Expression Transformation CLI")
        {
            scriptArg,
            inputOption,
            outputOption,
            metaOption,
            formatOption,
            watchOption
        };

        rootCommand.SetHandler(async (script, input, output, meta, format, watch) =>
        {
            await RunScript(script, input, output, meta, format, watch);
        }, scriptArg, inputOption, outputOption, metaOption, formatOption, watchOption);

        return await rootCommand.InvokeAsync(args);
    }

    private static async Task RunScript(
        FileInfo scriptFile,
        FileInfo? inputFile,
        FileInfo? outputFile,
        FileInfo? metaFile,
        OutputFormat format,
        bool watch)
    {
        if (!scriptFile.Exists)
        {
            WriteError($"Script file not found: {scriptFile.FullName}", format);
            Environment.ExitCode = 1;
            return;
        }

        // Find input file if not specified
        inputFile ??= FindCompanionFile(scriptFile, ".input.json");

        if (watch)
        {
            await WatchAndRun(scriptFile, inputFile, outputFile, metaFile, format);
        }
        else
        {
            var result = await ExecuteOnce(scriptFile, inputFile, metaFile);
            WriteResult(result, outputFile, format);
            Environment.ExitCode = result.Success ? 0 : 1;
        }
    }

    private static async Task<ExecutionResult> ExecuteOnce(
        FileInfo scriptFile,
        FileInfo? inputFile,
        FileInfo? metaFile)
    {
        var stopwatch = System.Diagnostics.Stopwatch.StartNew();

        try
        {
            var script = await File.ReadAllTextAsync(scriptFile.FullName);

            JToken input = new JObject();
            if (inputFile?.Exists == true)
            {
                var inputJson = await File.ReadAllTextAsync(inputFile.FullName);
                input = JToken.Parse(inputJson);
            }

            JToken? meta = null;
            if (metaFile?.Exists == true)
            {
                var metaJson = await File.ReadAllTextAsync(metaFile.FullName);
                meta = JToken.Parse(metaJson);
            }

            var jex = new JexEngine();
            var program = jex.Compile(script);
            var output = program.Execute(input, meta);

            stopwatch.Stop();

            return new ExecutionResult
            {
                Success = true,
                Output = output as JObject ?? new JObject { ["result"] = output },
                Variables = ExtractVariables(jex),
                ExecutionTimeMs = stopwatch.ElapsedMilliseconds,
                ScriptPath = scriptFile.FullName,
                InputPath = inputFile?.FullName
            };
        }
        catch (JexCompileException ex)
        {
            stopwatch.Stop();
            return new ExecutionResult
            {
                Success = false,
                Errors = [new ErrorInfo
                {
                    Message = ex.Message,
                    Line = ex.Span?.Start.Line ?? 0,
                    Column = ex.Span?.Start.Column ?? 0,
                    Type = "CompileError"
                }],
                ExecutionTimeMs = stopwatch.ElapsedMilliseconds,
                ScriptPath = scriptFile.FullName,
                InputPath = inputFile?.FullName
            };
        }
        catch (JexRuntimeException ex)
        {
            stopwatch.Stop();
            return new ExecutionResult
            {
                Success = false,
                Errors = [new ErrorInfo
                {
                    Message = ex.Message,
                    Line = ex.Span?.Start.Line ?? 0,
                    Column = ex.Span?.Start.Column ?? 0,
                    Type = "RuntimeError"
                }],
                ExecutionTimeMs = stopwatch.ElapsedMilliseconds,
                ScriptPath = scriptFile.FullName,
                InputPath = inputFile?.FullName
            };
        }
        catch (Exception ex)
        {
            stopwatch.Stop();
            return new ExecutionResult
            {
                Success = false,
                Errors = [new ErrorInfo
                {
                    Message = ex.Message,
                    Type = "Error"
                }],
                ExecutionTimeMs = stopwatch.ElapsedMilliseconds,
                ScriptPath = scriptFile.FullName,
                InputPath = inputFile?.FullName
            };
        }
    }

    private static Dictionary<string, object?> ExtractVariables(JexEngine jex)
    {
        // Note: This would need JEX to expose variable state after execution
        // For now, return empty - can be enhanced if JEX exposes this
        return new Dictionary<string, object?>();
    }

    private static async Task WatchAndRun(
        FileInfo scriptFile,
        FileInfo? inputFile,
        FileInfo? outputFile,
        FileInfo? metaFile,
        OutputFormat format)
    {
        Console.WriteLine($"Watching for changes... (Ctrl+C to stop)");
        Console.WriteLine($"  Script: {scriptFile.Name}");
        if (inputFile != null) Console.WriteLine($"  Input:  {inputFile.Name}");
        Console.WriteLine();

        var filesToWatch = new List<string> { scriptFile.FullName };
        if (inputFile?.Exists == true) filesToWatch.Add(inputFile.FullName);
        if (metaFile?.Exists == true) filesToWatch.Add(metaFile.FullName);

        using var watcher = new FileSystemWatcher(scriptFile.DirectoryName!);
        watcher.NotifyFilter = NotifyFilters.LastWrite;
        watcher.EnableRaisingEvents = true;

        var lastRun = DateTime.MinValue;
        var debounceMs = 300;

        watcher.Changed += async (sender, e) =>
        {
            if (!filesToWatch.Contains(e.FullPath)) return;
            if ((DateTime.Now - lastRun).TotalMilliseconds < debounceMs) return;

            lastRun = DateTime.Now;
            await Task.Delay(100); // Wait for file to be fully written

            Console.Clear();
            Console.WriteLine($"[{DateTime.Now:HH:mm:ss}] Running...\n");

            var result = await ExecuteOnce(scriptFile, inputFile, metaFile);
            WriteResult(result, outputFile, format);

            Console.WriteLine("\nWatching for changes... (Ctrl+C to stop)");
        };

        // Initial run
        var initialResult = await ExecuteOnce(scriptFile, inputFile, metaFile);
        WriteResult(initialResult, outputFile, format);
        Console.WriteLine("\nWatching for changes... (Ctrl+C to stop)");

        // Wait forever
        await Task.Delay(Timeout.Infinite);
    }

    private static FileInfo? FindCompanionFile(FileInfo scriptFile, string suffix)
    {
        var baseName = Path.GetFileNameWithoutExtension(scriptFile.Name);
        var companionPath = Path.Combine(scriptFile.DirectoryName!, baseName + suffix);

        if (File.Exists(companionPath))
        {
            return new FileInfo(companionPath);
        }

        return null;
    }

    private static void WriteResult(ExecutionResult result, FileInfo? outputFile, OutputFormat format)
    {
        string output = format switch
        {
            OutputFormat.Json => SerializeJson(result.Output ?? new JObject()),
            OutputFormat.Pretty => SerializePretty(result.Output ?? new JObject()),
            OutputFormat.Detailed => SerializeDetailed(result),
            _ => SerializeJson(result.Output ?? new JObject())
        };

        if (!result.Success)
        {
            if (format == OutputFormat.Detailed)
            {
                output = SerializeDetailed(result);
            }
            else
            {
                WriteError(result.Errors?.FirstOrDefault()?.Message ?? "Unknown error", format);
                return;
            }
        }

        if (outputFile != null)
        {
            File.WriteAllText(outputFile.FullName, output);
            Console.WriteLine($"Output written to: {outputFile.FullName}");
        }
        else
        {
            Console.WriteLine(output);
        }
    }

    private static void WriteError(string message, OutputFormat format)
    {
        if (format == OutputFormat.Detailed)
        {
            var result = new ExecutionResult
            {
                Success = false,
                Errors = [new ErrorInfo { Message = message, Type = "Error" }]
            };
            Console.Error.WriteLine(SerializeDetailed(result));
        }
        else
        {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.Error.WriteLine($"Error: {message}");
            Console.ResetColor();
        }
    }

    private static string SerializeJson(JObject obj)
    {
        return obj.ToString(Newtonsoft.Json.Formatting.None);
    }

    private static string SerializePretty(JObject obj)
    {
        return obj.ToString(Newtonsoft.Json.Formatting.Indented);
    }

    private static string SerializeDetailed(ExecutionResult result)
    {
        var options = new JsonSerializerOptions
        {
            WriteIndented = true,
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase
        };
        return JsonSerializer.Serialize(result, options);
    }
}

public enum OutputFormat
{
    Json,
    Pretty,
    Detailed
}

public class ExecutionResult
{
    public bool Success { get; set; }
    public JObject? Output { get; set; }
    public Dictionary<string, object?>? Variables { get; set; }
    public List<ErrorInfo>? Errors { get; set; }
    public long ExecutionTimeMs { get; set; }
    public string? ScriptPath { get; set; }
    public string? InputPath { get; set; }
}

public class ErrorInfo
{
    public string Message { get; set; } = "";
    public int Line { get; set; }
    public int Column { get; set; }
    public string Type { get; set; } = "Error";
}
