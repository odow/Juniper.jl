"""
branch_mostinfeasible(m, node, disc2var_idx)

Get the index of an integer variable which is currently continuous which is most unintegral.
(nearest to *.5)
"""
function branch_mostinfeasible(m, node, disc2var_idx)
    x = node.solution
    idx = 0
    max_diff = 0
    for i in disc2var_idx
        diff = abs(x[i]-round(x[i]))
        if diff > max_diff
            idx = i
            max_diff = diff
        end
    end
    return idx
end

"""
init_strong_restart!(node, var_idx, int_var_idx, l_nd, r_nd, reasonable_int_vars, infeasible_int_vars,
 left_node, right_node, strong_restart)

Tighten the bounds for the node and check if there are variables that need to be checked for a restart.
"""
function init_strong_restart!(node, var_idx, int_var_idx, l_nd, r_nd, 
                                reasonable_int_vars, infeasible_int_vars, 
                                left_node, right_node, strong_restart)
    restart = false
    set_to_last_var = false

    # set the bounds directly for the node
    # also update the best bound and the solution
    if l_nd.relaxation_state != :Optimal
        node.l_var[var_idx] = ceil(node.solution[var_idx])
        node.best_bound = r_nd.best_bound
        node.solution = r_nd.solution
    else
        node.u_var[var_idx] = floor(node.solution[var_idx])
        node.best_bound = l_nd.best_bound
        node.solution = l_nd.solution
    end

    push!(infeasible_int_vars, int_var_idx)

    if length(reasonable_int_vars) == length(infeasible_int_vars)
        # basically branching on the last infeasible variable 
        set_to_last_var = true
    elseif strong_restart
        restart = true
    end
    return restart, infeasible_int_vars, set_to_last_var
end

"""
    branch_strong_on!(m,opts,step_obj,reasonable_int_vars, disc2var_idx, strong_restart, counter)

Try to branch on a few different variables and choose the one with highest obj_gain.
Update obj_gain for the variables tried and average the other ones.
"""
function branch_strong_on!(m,opts,step_obj,
    reasonable_int_vars, disc2var_idx, strong_restart, counter)

    function set_temp_gains!(gains, gain_l, gain_r, int_var_idx)
        if !isinf(gain_l)
            gains.minus[int_var_idx] = gain_l
            gains.minus_counter[int_var_idx] = 1
        else 
            gains.inf_counter[int_var_idx] = 1
        end
        if !isinf(gain_r)
            gains.plus[int_var_idx] = gain_r
            gains.plus_counter[int_var_idx] = 1
        else 
            gains.inf_counter[int_var_idx] = 1
        end

        if !isinf(gain_l) && !isinf(gain_r)
            gains.inf_counter[int_var_idx] -= 1
        end
    end

    function get_current_gains(node, l_nd, r_nd)
        gain_l = sigma_minus(node, l_nd, node.solution[node.var_idx])
        gain_r = sigma_plus(node,  r_nd, node.solution[node.var_idx])

        if isinf(gain_l)
            gain = gain_r
        elseif isinf(gain_r)
            gain = gain_l
        else
            gain = (gain_l+gain_r)/2
        end
        if isnan(gain)
            gain = Inf
        end
        return gain_l, gain_r, gain
    end

    strong_time = time()

    node = step_obj.node

    left_node = nothing
    right_node = nothing

    max_gain = -Inf # then one is definitely better
    max_gain_var = 0
    max_gain_int_var = 0
    strong_restarts = -1
    restart = true
    status = :Normal
    node = step_obj.node
    infeasible_int_vars = zeros(Int64,0)
    gains = init_gains(m.num_disc_var)
  
    left_node, right_node = nothing, nothing
    atol = opts.atol

    need_to_resolve = false

    while restart 
        strong_restarts += 1 # is init with -1
        restart = false
        for int_var_idx in reasonable_int_vars
            # don't rerun if the variable has already one infeasible node
            if int_var_idx in infeasible_int_vars
                continue
            end
            var_idx = disc2var_idx[int_var_idx]
            step_obj.var_idx = var_idx
            u_b, l_b = node.u_var[var_idx], node.l_var[var_idx]
            # don't rerun if bounds are exact or is type correct
            if isapprox(u_b,l_b; atol=atol) || is_type_correct(node.solution[var_idx],m.var_type[var_idx], atol)
                continue
            end

            # branch on the current variable and get the corresponding children
            l_nd,r_nd = branch!(m, opts, step_obj, counter, disc2var_idx; temp=true)

            # no current restart => we can set max_gain and variable
            gain_l, gain_r, gain = get_current_gains(node, l_nd, r_nd)

            if l_nd.relaxation_state != :Optimal && r_nd.relaxation_state != :Optimal && counter == 1
                # TODO: Might be Error/UserLimit instead of infeasible
                status = :GlobalInfeasible
                left_node = l_nd
                right_node = r_nd
                break
            end

            # check if one part is infeasible => update bounds & restart if strong restart is true
            if l_nd.relaxation_state != :Optimal || r_nd.relaxation_state != :Optimal
                if l_nd.relaxation_state != :Optimal && r_nd.relaxation_state != :Optimal
                    # TODO: Might be Error/UserLimit instead of infeasible
                    status = :LocalInfeasible
                    left_node = l_nd
                    right_node = r_nd
                    break
                end
                restart,new_infeasible_int_vars,set_to_last_var = init_strong_restart!(node, var_idx, int_var_idx, l_nd, r_nd, reasonable_int_vars, infeasible_int_vars, left_node, right_node, strong_restart)
                infeasible_int_vars = new_infeasible_int_vars

                need_to_resolve = true
                # only variables where one branch is infeasible => no restart and break
                if set_to_last_var
                    max_gain_var = var_idx
                    max_gain_int_var = int_var_idx
                    left_node = l_nd
                    right_node = r_nd
                    restart = false
                    need_to_resolve = false
                    gain_l, gain_r, gain = get_current_gains(node, l_nd, r_nd)
                    max_gain = gain
                    set_temp_gains!(gains, gain_l, gain_r, int_var_idx)
                    break
                end

                if restart && time()-strong_time > opts.strong_branching_approx_time_limit
                    restart = false
                end
            end

            # don't update maximum if restart
            if gain > max_gain && !restart 
                max_gain = gain
                max_gain_var = var_idx
                max_gain_int_var = int_var_idx
                left_node = l_nd
                right_node = r_nd
                # we are changing the bounds if one branch is infeasible then the current
                # selection might not work anymore => we have to resolve it later
                need_to_resolve = false
            end
            set_temp_gains!(gains, gain_l, gain_r, int_var_idx)
            if restart
                break
            end

            if time()-m.start_time >= opts.time_limit
                break
            end
        end
    end

    # check if need to resolve (not if Local/Global Infeasible)
    if need_to_resolve && status == :Normal 
        status = :Resolve
    end

    return status, max_gain_var, left_node, right_node, gains, strong_restarts
end

"""
branch_strong!(m,opts,disc2var_idx,step_obj,counter)

Try to branch on a few different variables and choose the one with highest obj_gain.
Update obj_gain for the variables tried and average the other ones.
"""
function branch_strong!(m,opts,disc2var_idx,step_obj,counter)
    node = step_obj.node

    # generate an of variables to branch on
    num_strong_var = Int(round((opts.strong_branching_perc/100)*m.num_disc_var))
    # if smaller than 2 it doesn't make sense
    num_strong_var = num_strong_var < 2 ? 2 : num_strong_var
    # use strong_branching_approx_time_limit to change num_strong_var
    if !isinf(opts.strong_branching_approx_time_limit)
        approx_time_per_node = 2*m.relaxation_time
        new_num_strong_var = Int(floor(opts.strong_branching_approx_time_limit/approx_time_per_node))
        new_num_strong_var = new_num_strong_var == 0 ? 1 : new_num_strong_var
        if new_num_strong_var < num_strong_var
            @warn "Changed num_strong_var to $new_num_strong_var because of strong_branching_approx_time_limit"
            num_strong_var = new_num_strong_var
        end
    end

    # get reasonable candidates (not type correct and not already perfectly bounded)
    int_vars = m.num_disc_var
    atol = opts.atol
    reasonable_int_vars = get_reasonable_int_vars(node, m.var_type, int_vars,  disc2var_idx, atol)
    if num_strong_var < length(reasonable_int_vars)
        shuffle!(reasonable_int_vars)
        reasonable_int_vars = reasonable_int_vars[1:num_strong_var]
    end

    # compute the gain for each reasonable candidate and choose the highest
    left_node = nothing
    right_node = nothing

    status, max_gain_var,  left_node, right_node, gains, strong_restarts = branch_strong_on!(m,opts,step_obj,
        reasonable_int_vars, disc2var_idx, opts.strong_restart, counter)

    step_obj.obj_gain += gains

    if status != :Resolve
        step_obj.l_nd = left_node
        step_obj.r_nd = right_node
    
        # set the variable to branch (best gain)
        node.state = :Done
        node.var_idx = max_gain_var
    end


    @assert max_gain_var != 0 || status == :LocalInfeasible || status == :GlobalInfeasible || node.state == :Infeasible
    return status, max_gain_var, strong_restarts
end

function branch_reliable!(m,opts,step_obj,disc2var_idx,gains,counter) 
    idx = 0
    node = step_obj.node
    mu = opts.gain_mu
    reliability_param = opts.reliability_branching_threshold
    reliability_perc = opts.reliability_branching_perc
    num_strong_var = Int(round((reliability_perc/100)*m.num_disc_var))
    # if smaller than 2 it doesn't make sense
    num_strong_var = num_strong_var < 2 ? 2 : num_strong_var

    # use strong_branching_approx_time_limit to change num_strong_var
    if !isinf(opts.strong_branching_approx_time_limit)
        approx_time_per_node = 2*m.relaxation_time
        new_num_strong_var = Int(floor(opts.strong_branching_approx_time_limit/approx_time_per_node))
        new_num_strong_var = new_num_strong_var == 0 ? 1 : new_num_strong_var
        if new_num_strong_var < num_strong_var
            @warn "Changed num_strong_var to $new_num_strong_var because of strong_branching_approx_time_limit"
            num_strong_var = new_num_strong_var
        end
    end


    gmc_r = gains.minus_counter .< reliability_param
    gpc_r = gains.plus_counter  .< reliability_param

    strong_restarts = 0
    reasonable_int_vars = []
    atol = opts.atol
    for i=1:length(gmc_r)
        if gmc_r[i] || gpc_r[i]
            idx = disc2var_idx[i]
            u_b = node.u_var[idx]
            l_b = node.l_var[idx]
            if isapprox(u_b,l_b; atol=atol) || is_type_correct(node.solution[idx],m.var_type[idx],atol)
                continue
            end
            push!(reasonable_int_vars,i)
        end
    end
    if length(reasonable_int_vars) > 0
        unrealiable_idx = sortperm(gains.minus_counter[reasonable_int_vars])
        reasonable_int_vars = reasonable_int_vars[unrealiable_idx]
        num_reasonable = num_strong_var < length(reasonable_int_vars) ? num_strong_var : length(reasonable_int_vars)
        reasonable_int_vars = reasonable_int_vars[1:num_reasonable]
        
        status, max_gain_var, left_node, right_node, gains, strong_restarts = branch_strong_on!(m,opts,step_obj,
            reasonable_int_vars, disc2var_idx, opts.strong_restart, counter)
        
        step_obj.obj_gain += gains
        
        step_obj.upd_gains = :GainsToTree
        new_gains = copy(step_obj.obj_gain)
        
        if status == :GlobalInfeasible
            return :GlobalInfeasible, 0, strong_restarts
        end
    else 
        step_obj.upd_gains = :GuessAndUpdate
        new_gains = copy(gains)
    end
    idx = branch_pseudo(m, node, disc2var_idx, new_gains, mu, atol)
    return :Normal, idx, strong_restarts
end

function branch_pseudo(m, node, disc2var_idx, obj_gain, mu, atol)
    # use the one with highest obj_gain which is currently continous
    idx = 0
    scores, sort_idx = sorted_score_idx(node.solution, obj_gain, disc2var_idx, mu)
    for l_idx in sort_idx
        var_idx = disc2var_idx[l_idx]
        if !is_type_correct(node.solution[var_idx], m.var_type[var_idx], atol)
            u_b = node.u_var[var_idx]
            l_b = node.l_var[var_idx]
            # if the upper bound is the lower bound => should be type correct
            @assert !isapprox(u_b, l_b; atol=atol)
            idx = var_idx
            break
        end
    end
    return idx
end

function sorted_score_idx(x, gains, i2v, mu)
    g_minus, g_minus_c = gains.minus, gains.minus_counter
    g_plus, g_plus_c = gains.plus, gains.plus_counter
    g_minus_c += map(i -> (i == 0) && (i = 1), g_minus_c)
    g_plus_c += map(i -> (i == 0) && (i = 1), g_plus_c)
    scores = [score(f_minus(x[i2v[i]])*g_minus[i]/g_minus_c[i],f_plus(x[i2v[i]])*g_plus[i]/g_plus_c[i],mu) for i=1:length(g_minus)]
    sortedidx = sortperm(scores; rev=true)
    infsortedidx = sortperm(gains.inf_counter[sortedidx]; rev=true)
    return scores,sortedidx[infsortedidx]
end

"""
    Score function from 
    http://citeseerx.ist.psu.edu/viewdoc/download?doi=10.1.1.92.7117&rep=rep1&type=pdf
"""
function score(q_m, q_p, mu) 
    minq = q_m < q_p ? q_m : q_p
    maxq = q_m < q_p ? q_p : q_m
    return (1-mu)*minq+mu*maxq
end

function diff_obj(node, cnode)
    if cnode.relaxation_state == :Optimal
        return abs(node.best_bound - cnode.best_bound)
    else
        return Inf
    end
end

f_plus(x) = ceil(x)-x
f_minus(x) = x-floor(x)
sigma_plus(node,r_nd,x) = diff_obj(node,r_nd)/f_plus(x)
sigma_minus(node,l_nd,x) = diff_obj(node,l_nd)/f_minus(x)