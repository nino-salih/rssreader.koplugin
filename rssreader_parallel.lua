--[[--
Runs independent jobs in a few forked worker processes (KOReader's
ffiutil.runInSubProcess with a pipe) and returns their results to the parent.

The work is latency bound (HTTP requests): N requests one after the other cost
about N times the latency of one, a few workers cut that down. Every worker
gets a round-robin bucket of jobs, runs them one after the other and writes
all its results through its pipe, serialised with LuaJIT's string.buffer
(the same way Trapper:dismissableRunInSubprocess does). Results must therefore
be plain data (no functions, no cdata). A job that raises an error has no result.

Without fork support (emulator without ffiutil, specs), with one worker or one
job the jobs run in the parent, one after the other.

    local results, cancelled = Parallel.run(jobs, run, opts)

  jobs     list of job inputs
  run      function(job) -> result (runs in the worker process)
  opts     workers        1..8 (default 4), capped at #jobs
           on_poll(done, total) -> false cancels; called before each job when
                          sequential, and on every poll while workers run
           wait(seconds) -> false cancels; pause between polls (default socket.sleep)
           ffiutil        fork API (default require("ffi/util"); injected by specs)
           collect_later(pids) reaps killed workers later (default: UIManager timer)
  results  index -> result (nil = failed or not run), cancelled = boolean
]]

local Parallel = {}

Parallel.DEFAULT_WORKERS = 4
Parallel.MAX_WORKERS = 8
Parallel.POLL_INTERVAL = 0.25 -- seconds between "are the workers done?" checks

--- Pure: number of workers for `count` jobs (1..MAX_WORKERS, at most `count`).
function Parallel.workerCount(workers, count)
    local wanted = math.floor(tonumber(workers) or Parallel.DEFAULT_WORKERS)
    wanted = math.max(1, math.min(Parallel.MAX_WORKERS, wanted))
    return math.max(1, math.min(wanted, count))
end

--- Pure: job indexes per worker, round-robin, so a worker that draws a slow
-- host does not also get all the jobs next to it.
function Parallel.buckets(count, workers)
    local buckets = {}
    for index = 1, count do
        local slot = (index - 1) % workers + 1
        buckets[slot] = buckets[slot] or {}
        table.insert(buckets[slot], index)
    end
    return buckets
end

local function runJob(run, job)
    local ok, result = pcall(run, job)
    if ok then
        return result
    end
    require("logger").warn("RSSReader parallel: job failed", result)
    return nil
end

local function sequential(jobs, run, opts)
    local results, total = {}, #jobs
    for index, job in ipairs(jobs) do
        if opts.on_poll and opts.on_poll(index - 1, total) == false then
            return results, true
        end
        results[index] = runJob(run, job)
    end
    return results, false
end

-- Killed workers still have to be reaped (and their pipes closed); the same
-- approach as Trapper: a UIManager timer instead of blocking here.
local function collectLater(ffiutil, workers)
    local ok, UIManager = pcall(require, "ui/uimanager")
    if not ok or not UIManager then
        return
    end
    local collect
    collect = function()
        for i = #workers, 1, -1 do
            if ffiutil.isSubProcessDone(workers[i].pid) then
                ffiutil.readAllFromFD(workers[i].fd)
                table.remove(workers, i)
            end
        end
        if #workers > 0 then
            UIManager:scheduleIn(5, collect)
        end
    end
    UIManager:scheduleIn(5, collect)
end

local function startWorker(ffiutil, jobs, run, bucket)
    return ffiutil.runInSubProcess(function(_pid, write_fd)
        local buffer = require("string.buffer")
        local results = {}
        for _, index in ipairs(bucket) do
            results[index] = runJob(run, jobs[index])
        end
        local ok, data = pcall(buffer.encode, results)
        ffiutil.writeToFD(write_fd, ok and data or "", true)
    end, true)
end

-- Reads a finished worker's results into `results`; returns the job count.
local function collectWorker(ffiutil, worker, results)
    local data = ffiutil.readAllFromFD(worker.fd)
    if not worker.done then
        ffiutil.isSubProcessDone(worker.pid, true) -- it exits right after writing
    end
    local ok, decoded = pcall(require("string.buffer").decode, data)
    if ok and type(decoded) == "table" then
        for index, result in pairs(decoded) do
            results[index] = result
        end
    end
    return #worker.bucket
end

local function parallel(jobs, run, opts, ffiutil, worker_count)
    local results, total, done = {}, #jobs, 0
    local running = {}
    for _, bucket in ipairs(Parallel.buckets(total, worker_count)) do
        local pid, fd = startWorker(ffiutil, jobs, run, bucket)
        if pid then
            table.insert(running, { pid = pid, fd = fd, bucket = bucket })
        else
            -- fork() failed: this bucket is on us, right here.
            require("logger").warn("RSSReader parallel: could not fork a worker", fd)
            for _, index in ipairs(bucket) do
                results[index] = runJob(run, jobs[index])
            end
            done = done + #bucket
        end
    end

    local wait = opts.wait or function(seconds)
        require("socket").sleep(seconds)
        return true
    end
    local cancelled = false
    while true do
        for i = #running, 1, -1 do
            local worker = running[i]
            worker.done = ffiutil.isSubProcessDone(worker.pid)
            -- A worker with more output than the pipe holds blocks in write()
            -- until we read: readable output counts as finished, too.
            if worker.done or ffiutil.getNonBlockingReadSize(worker.fd) ~= 0 then
                done = done + collectWorker(ffiutil, worker, results)
                table.remove(running, i)
            end
        end
        if opts.on_poll and opts.on_poll(done, total) == false then
            cancelled = true
        elseif #running > 0 and wait(Parallel.POLL_INTERVAL) == false then
            cancelled = true
        end
        if cancelled or #running == 0 then
            break
        end
    end

    if cancelled and #running > 0 then
        for _, worker in ipairs(running) do
            ffiutil.terminateSubProcess(worker.pid)
        end
        local later = opts.collect_later or function(workers) collectLater(ffiutil, workers) end
        later(running)
    end
    return results, cancelled
end

--- See the module comment. Returns results (index -> result), cancelled.
function Parallel.run(jobs, run, opts)
    opts = opts or {}
    local ffiutil = opts.ffiutil
    if not ffiutil then
        local ok, module = pcall(require, "ffi/util")
        ffiutil = ok and module or {}
    end
    local worker_count = Parallel.workerCount(opts.workers, #jobs)
    if worker_count <= 1 or type(ffiutil.runInSubProcess) ~= "function" then
        return sequential(jobs, run, opts)
    end
    return parallel(jobs, run, opts, ffiutil, worker_count)
end

return Parallel
