-- Execution-only adapter for an isolated nfqws2 learning instance.
-- The controller supplies the strategy through C/conntrack; this module
-- neither rotates nor persists strategy state. Missing C attribution fails
-- closed by passing the packet without desynchronization.
function adaptive_execute(ctx, desync)
  if type(desync) ~= "table" or not flow_strategy_assign then
    return VERDICT_PASS
  end

  local scope = desync.arg and desync.arg.scope or "default"
  local selected = flow_strategy_assign(desync, 1, scope)
  if type(selected) ~= "number" or selected < 1 then
    return VERDICT_PASS
  end

  local verdict = VERDICT_PASS
  while true do
    local instance = plan_instance_pop(desync)
    if not instance then break end
    if instance.arg and tonumber(instance.arg.strategy) == selected then
      verdict = plan_instance_execute(desync, verdict, instance)
    end
  end
  return verdict
end
