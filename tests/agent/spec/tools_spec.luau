--!nonstrict
local T = require("../support/t")
local json = require("../support/json")
local Tools = require("../../../system_files/usr/share/madeofblue/noctalia-plugins/agent/lib/tools")

local function fakeIo(files)
  local io = { home = "/home/u", runs = {}, writes = {} }
  io.expandPath = function(p)
    return (string.gsub(p, "^~", "/home/u"))
  end
  io.run = function(argv, cb)
    table.insert(io.runs, { argv = argv, cb = cb })
    return true
  end
  io.readFile = function(p)
    if files and files[p] ~= nil then
      return files[p]
    end
    return nil, "no such file"
  end
  io.writeFile = function(p, content)
    io.writes[p] = content
    return true
  end
  return io
end

T.describe("tools", function()
  T.it("exposes three tool schemas", function()
    T.eq(#Tools.SCHEMAS, 3)
    T.eq(Tools.SCHEMAS[1].name, "run_command")
    T.eq(Tools.SCHEMAS[1].parameters.required[1], "command")
  end)

  T.it("parses valid arguments and rejects bad ones", function()
    T.eq(Tools.parseArgs("run_command", '{"command":"ls"}', json).command, "ls")
    local _, e1 = Tools.parseArgs("run_command", '{"cmd":"ls"}', json)
    T.contains(e1, "command")
    local _, e2 = Tools.parseArgs("run_command", "{oops", json)
    T.contains(e2, "JSON")
    local _, e3 = Tools.parseArgs("rm_rf", "{}", json)
    T.contains(e3, "unknown tool")
    T.eq(Tools.parseArgs("write_file", '{"path":"a","content":""}', json).content, "")
  end)

  T.it("runs commands under a timeout via sh -c", function()
    local io = fakeIo()
    local got
    Tools.execute("run_command", { command = "echo hi" }, io, function(out)
      got = out
    end)
    local argv = io.runs[1].argv
    T.eq(argv[1], "timeout")
    T.eq(argv[#argv - 1], "-c")
    T.eq(argv[#argv], "echo hi")
    io.runs[1].cb({ exitCode = 0, stdout = "hi\n", stderr = "" })
    T.eq(got, "exit code: 0\nstdout:\nhi\n")
  end)

  T.it("reports timeouts", function()
    local io = fakeIo()
    local got
    Tools.execute("run_command", { command = "sleep 999" }, io, function(out)
      got = out
    end)
    io.runs[1].cb({ exitCode = 124, stdout = "", stderr = "" })
    T.contains(got, "timed out after 120s")
  end)

  T.it("resolves relative paths against home and reads files", function()
    local io = fakeIo({ ["/home/u/notes.txt"] = "hello", ["/home/u/empty"] = "" })
    local got
    Tools.execute("read_file", { path = "notes.txt" }, io, function(out)
      got = out
    end)
    T.eq(got, "hello")
    Tools.execute("read_file", { path = "~/empty" }, io, function(out)
      got = out
    end)
    T.eq(got, "(empty file)")
    Tools.execute("read_file", { path = "/nope" }, io, function(out)
      got = out
    end)
    T.contains(got, "no such file")
  end)

  T.it("writes files", function()
    local io = fakeIo()
    local got
    Tools.execute("write_file", { path = "~/a.txt", content = "abc" }, io, function(out)
      got = out
    end)
    T.eq(io.writes["/home/u/a.txt"], "abc")
    T.eq(got, "wrote 3 bytes to ~/a.txt")
  end)

  T.it("returns command output and file contents whole, for the agent to scrub first", function()
    local long = string.rep("a", 9000) .. "\255" .. string.rep("b", 9000)
    local io = fakeIo({ ["/home/u/big"] = long })
    local got
    Tools.execute("run_command", { command = "cat big" }, io, function(out)
      got = out
    end)
    io.runs[1].cb({ exitCode = 0, stdout = long, stderr = "" })
    T.eq(got, "exit code: 0\nstdout:\n" .. long)
    Tools.execute("read_file", { path = "~/big" }, io, function(out)
      got = out
    end)
    T.eq(got, long)
  end)

  T.it("truncates long output keeping head and tail", function()
    local long = string.rep("a", 9000) .. string.rep("b", 9000)
    local out = Tools.truncate(long)
    T.contains(out, "bytes truncated")
    T.eq(string.sub(out, 1, 1), "a")
    T.eq(string.sub(out, -1), "b")
    T.truthy(#out < #long)
  end)

  T.it("replaces invalid UTF-8", function()
    T.eq(Tools.sanitizeUtf8("ok\255ok"), "ok?ok")
    T.eq(Tools.sanitizeUtf8("café"), "café")
  end)

  T.it("describes calls for approval cards", function()
    local view = Tools.describe("write_file", { path = "~/x", content = "body" })
    T.eq(view.title, "Write file")
    T.contains(view.body, "~/x")
    T.contains(view.body, "body")
    local long = string.rep("x", 10000) .. "TAIL"
    T.eq(Tools.describe("write_file", { path = "~/x", content = long }).body, "~/x\n\n" .. long, "the whole content is shown")
    T.eq(Tools.subject("run_command", { command = "ls" }), "ls")
    T.eq(Tools.subject("read_file", { path = "/etc/hosts" }), "/etc/hosts")
  end)

  T.it("checks file tools against the resolved absolute path", function()
    local io = fakeIo()
    T.eq(Tools.subject("read_file", { path = "/home/u/x/../.local/state/agent/config.json" }, io), "/home/u/.local/state/agent/config.json")
    T.eq(Tools.subject("write_file", { path = "~/a/./b//c/..", content = "" }, io), "/home/u/a/b")
    T.eq(Tools.subject("read_file", { path = "notes/../../../etc/shadow" }, io), "/etc/shadow")
    T.eq(Tools.subject("read_file", { path = "/../../etc" }, io), "/etc")
    T.eq(Tools.subject("run_command", { command = "cat a/../b" }, io), "cat a/../b")
  end)

  T.it("opens the path it checked", function()
    local io = fakeIo({ ["/home/u/b"] = "B" })
    local got
    Tools.execute("read_file", { path = "~/a/../b" }, io, function(out)
      got = out
    end)
    T.eq(got, "B")
    Tools.execute("write_file", { path = "~/a/../c", content = "C" }, io, function() end)
    T.eq(io.writes["/home/u/c"], "C")
  end)
end)

return true
