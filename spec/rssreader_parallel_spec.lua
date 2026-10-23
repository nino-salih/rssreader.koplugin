local Parallel = require("rssreader_parallel")

-- Fake of KOReader's ffi/util fork API: a "child" runs at once in this process;
-- its pipe is a string. `opts.fail_fork` = number of forks that fail;
-- `opts.running` = pids that stay running until terminated.
local function fakeFork(opts)
    opts = opts or {}
    local fork = { forks = 0, terminated = {}, pipes = {}, next_pid = 100 }
    function fork.runInSubProcess(func, with_pipe)
        assert.is_true(with_pipe)
        fork.forks = fork.forks + 1
        if (opts.fail_fork or 0) >= fork.forks then
            return false, "fork failed"
        end
        fork.next_pid = fork.next_pid + 1
        local pid = fork.next_pid
        fork.pipes[pid] = ""
        if not (opts.running and opts.running[fork.forks]) then
            func(pid, pid)
        end
        return pid, pid
    end
    function fork.writeToFD(fd, data)
        fork.pipes[fd] = fork.pipes[fd] .. data
        return true
    end
    function fork.readAllFromFD(fd)
        local data = fork.pipes[fd]
        fork.pipes[fd] = nil
        return data or ""
    end
    function fork.getNonBlockingReadSize(fd)
        return #(fork.pipes[fd] or "")
    end
    function fork.isSubProcessDone(pid)
        return fork.pipes[pid] ~= "" or fork.terminated[pid] == true
    end
    function fork.terminateSubProcess(pid)
        fork.terminated[pid] = true
    end
    return fork
end

describe("rssreader_parallel", function()
    it("splits jobs round-robin into at most `workers` buckets", function()
        assert.same({ { 1, 4 }, { 2, 5 }, { 3 } }, Parallel.buckets(5, 3))
        assert.same({ { 1 }, { 2 } }, Parallel.buckets(2, 4))
        assert.same({}, Parallel.buckets(0, 4))
    end)

    it("clamps the worker count to 1..8 (default 4) and to the job count", function()
        assert.equals(4, Parallel.workerCount(nil, 10))
        assert.equals(8, Parallel.workerCount(20, 10))
        assert.equals(1, Parallel.workerCount(0, 10))
        assert.equals(2, Parallel.workerCount(4, 2))
    end)

    it("runs jobs in forked workers and maps every result back to its job", function()
        local fork = fakeFork()
        local results, cancelled = Parallel.run({ "a", "b", "c", "d", "e" }, function(job)
            return { name = job:upper() }
        end, { workers = 2, ffiutil = fork, wait = function() return true end })
        assert.is_false(cancelled)
        assert.equals(2, fork.forks)
        assert.same({ { name = "A" }, { name = "B" }, { name = "C" }, { name = "D" }, { name = "E" } }, results)
    end)

    it("keeps the other results when a job raises an error", function()
        local results = Parallel.run({ 1, 2, 3 }, function(job)
            if job == 2 then
                error("boom")
            end
            return job * 10
        end, { workers = 3, ffiutil = fakeFork(), wait = function() return true end })
        assert.equals(10, results[1])
        assert.is_nil(results[2])
        assert.equals(30, results[3])
    end)

    it("runs one after the other without fork support, with one worker or one job", function()
        local order = {}
        local function run(job)
            table.insert(order, job)
            return job
        end
        assert.same({ "x", "y" }, (Parallel.run({ "x", "y" }, run, { workers = 4, ffiutil = {} })))
        local fork = fakeFork()
        assert.same({ "z" }, (Parallel.run({ "z" }, run, { workers = 4, ffiutil = fork })))
        assert.same({ "u", "v" }, (Parallel.run({ "u", "v" }, run, { workers = 1, ffiutil = fork })))
        assert.equals(0, fork.forks)
        assert.same({ "x", "y", "z", "u", "v" }, order)
    end)

    it("runs a bucket in the parent when the fork fails", function()
        local fork = fakeFork({ fail_fork = 1 })
        local results = Parallel.run({ 1, 2, 3, 4 }, function(job) return job + 1 end,
            { workers = 2, ffiutil = fork, wait = function() return true end })
        assert.same({ 2, 3, 4, 5 }, results)
    end)

    it("reports progress while polling and terminates the workers on cancel", function()
        local fork = fakeFork({ running = { [2] = true } })
        local polls = {}
        local results, cancelled = Parallel.run({ 1, 2, 3, 4 }, function(job) return job end, {
            workers = 2, ffiutil = fork, wait = function() return true end,
            on_poll = function(done, total)
                table.insert(polls, done .. "/" .. total)
                return #polls < 2
            end,
            collect_later = function() end,
        })
        assert.is_true(cancelled)
        assert.same({ "2/4", "2/4" }, polls)
        assert.same({ 1, nil, 3 }, { results[1], results[2], results[3] })
        assert.is_true(fork.terminated[102])
    end)

    it("stops waiting when the wait callback cancels", function()
        local fork = fakeFork({ running = { [1] = true } })
        local _, cancelled = Parallel.run({ 1, 2 }, function(job) return job end, {
            workers = 2, ffiutil = fork, wait = function() return false end, collect_later = function() end,
        })
        assert.is_true(cancelled)
    end)

    it("calls on_poll before each job when running sequentially and can be cancelled", function()
        local ran = {}
        local results, cancelled = Parallel.run({ "a", "b", "c" }, function(job)
            table.insert(ran, job)
            return job
        end, { workers = 1, on_poll = function(done) return done < 2 end })
        assert.is_true(cancelled)
        assert.same({ "a", "b" }, ran)
        assert.same({ "a", "b" }, results)
    end)
end)
