function set_task_status(task_key, status, varargin)
% Examples
% set_task_status('task:X', 'pending'/'finished')
% set_task_status({'task:X','task:Y'}, 'pending'/'finished')
% set_task_status('pending_tasks', 'finished') # to be implemented
% set_task_status('pre_pending_tasks', 'pending') # to be implemented

% DOC
% all possible task status: pre_pending, pending, ongoing, finished, failed
% all possible worker status: active, suspended, restart, kill, dead

if any(strcmpi(varargin, 'force'))
    force_flag = true; % used to restart worker to stop ongoing task
else
    force_flag = false;
end

if iscell(task_key)
    for cell_idx = 1:numel(task_key)
        if ~isempty(task_key{cell_idx})
            if force_flag
                mrc.set_task_status(task_key{cell_idx}, status, 'force');
            else
                mrc.set_task_status(task_key{cell_idx}, status);
            end
        end
    end
    return
end

task_key = char(task_key);
status = char(status);
redis = get_redis_connection;
if strcmpi(task_key, 'all')
    mrc.set_task_status({'all_pre_pending', 'all_pending', ...
        'all_ongoing', 'all_finished', 'all_failed'}, status)
elseif strcmpi(task_key, 'all_pre_pending')
    switch status
        case 'deleted'            
            redis.del('pre_pending_tasks');
        otherwise
            error('not implemented yet')
    end
elseif strcmpi(task_key, 'all_pending')
    switch status
        case 'deleted'
            redis.del('pending_tasks');            
        otherwise
            error('not implemented yet')
    end
elseif strcmpi(task_key, 'all_ongoing')
    switch status
        case 'deleted'
            mrc.set_worker_status('all', 'restart');
        otherwise
            error('not implemented yet')
    end
elseif strcmpi(task_key, 'all_finished')
    switch status
        case 'deleted'
            redis.del('finished_tasks');
        otherwise
            error('not implemented yet')
    end
elseif strcmpi(task_key, 'all_failed')
    switch status
        case 'deleted'
            redis.del('failed_tasks');
        otherwise
            error('not implemented yet')
    end
end

if ~strncmpi(task_key, 'task:', 5)
    return
end

task = get_redis_hash(task_key);
task = structfun(@char, task, 'UniformOutput', false);
switch status
    case 'pending'
        if any(strcmpi(task.status, {'pending', 'ongoing'}))
            return
        end
        redis.multi;
        redis.lrem([task.status '_tasks'], '0', task_key);
        redis.lpush('pending_tasks', task_key);
        redis.hmset(task_key, 'status', 'pending',  'str',  ['[' task.created_on  '] ' task.command])
        if strcmpi(task.status, 'ongoing') && force_flag
            redis.srem('available_workers', task.worker);
            redis.hset(task.worker, 'status', 'restart');
        end
        redis.exec;
    case 'finished'
        if strcmpi(task.status, 'finished')
            return
        end
        task_str = ['[' char(datetime)  '] (' task.worker ') ' task.command];
        sha = script_SHA('update_dependent_tasks');
        redis.multi;
        redis.evalsha(sha, '1', task_key);
        redis.lrem([task.status '_tasks'], '0', task_key);
        redis.lpush('finished_tasks', task_key);
        redis.hmset(task_key, 'finished_on', str_to_redis_str(datetime), 'status', 'finished', ...
            'str', str_to_redis_str(task_str));
        if strcmpi(task.status, 'ongoing') && force_flag
            redis.srem('available_workers', task.worker);
            redis.hset(task.worker, 'status', 'restart');
        end
        redis.exec;
    case 'failed'
        if strcmpi(task.fail_policy, 'continue')
            redis.evalsha(script_SHA('update_dependent_tasks'), '1', task_key);
        end        
        task_str = ['[' char(datetime)  '] (' task.worker ') ' task.command];
        
        redis.multi;
        redis.lrem([task.status '_tasks'], '0', task_key);
        redis.lpush('failed_tasks', task_key);
        redis.hmset(task_key, 'failed_on', str_to_redis_str(datetime), 'status', 'failed', ...
            'str', str_to_redis_str(task_str));
        redis.exec;
    case 'deleted'
        if strcmpi(task.status, 'ongoing')
            mrc.set_worker_status(task.worker, 'restart')           
        else
            redis.lrem([task.status '_tasks'], '0', task_key)
        end
    otherwise
        error([status ' status is not supported for tasks']);
end
end
