# Sandbox Tools Example
#
# Demonstrates the ListDirectory, WriteFile, ReadFile, and Shell tools
# with a Sandbox security configuration. The agent manages files in a
# temporary workspace with restricted permissions.
#
# Run with: mix run examples/sandbox_tools.exs
# Requires: OPENAI_API_KEY

unless System.get_env("OPENAI_API_KEY") do
  IO.puts("This example requires an OpenAI API key.")
  IO.puts("Set it with: export OPENAI_API_KEY=your-key-here")
  System.halt(1)
end

alias Agora.Tool.Sandbox

# Create a temporary workspace with starter files
workspace =
  Path.join(System.tmp_dir!(), "agora_sandbox_example_#{System.unique_integer([:positive])}")

File.mkdir_p!(workspace)
File.write!(Path.join(workspace, "notes.txt"), "Meeting at 3pm\nReview PR #42\nDeploy v2.1\n")
File.write!(Path.join(workspace, "data.csv"), "name,score\nAlice,95\nBob,87\nCarol,92\n")

try do
  sandbox = %Sandbox{
    working_directory: workspace,
    allowed_paths: [workspace],
    denied_commands: ["rm", "sudo", "chmod"],
    allow_shell_mode: false
  }

  config =
    Agora.agent(:openai, "gpt-4o",
      instructions: """
      You are a file manager. Follow these steps exactly:
      1. Use the list_directory tool to see what files are in the current directory (path ".")
      2. Use the read_file tool to read "notes.txt"
      3. Use the write_file tool to create "summary.txt" with a summary of the workspace contents
      4. Use the shell tool to count lines in data.csv (command: "wc", args: ["-l", "data.csv"])
      5. Report what you did
      """,
      tools: [
        Agora.Tool.ListDirectory,
        Agora.Tool.WriteFile,
        Agora.Tool.ReadFile,
        Agora.Tool.Shell
      ],
      tool_opts: [sandbox: sandbox]
    )

  IO.puts("=== Sandbox Tools Example ===\n")
  IO.puts("Workspace: #{workspace}")

  IO.puts(
    "Sandbox: allowed_paths=#{inspect(sandbox.allowed_paths)}, denied_commands=#{inspect(sandbox.denied_commands)}\n"
  )

  IO.puts("User: Organize the workspace — list files, create a summary, and count data rows.\n")

  {:ok, response} =
    Agora.run(
      config,
      "Organize this workspace — list files, read notes, create a summary, and count data rows."
    )

  IO.puts("Agent: #{response.content}")
after
  File.rm_rf!(workspace)
  IO.puts("\n(Cleaned up temporary workspace)")
end
