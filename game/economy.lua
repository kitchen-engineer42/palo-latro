-- Canonical P&L arithmetic. Callers pass state so simulation/UI cannot drift.

local Economy = {
  DEFAULT_MARGIN = 0.50,
  MAX_MARGIN = 0.95,
  MAX_MARGIN_BONUS = 0.30,
  SALARY_DIV = 350,
  INTEREST_DIV = 5,
}

function Economy.ante_base(g, ante_base)
  local ante = (g and g.ante) or 1
  return ante_base[ante] or ante_base[#ante_base]
end

function Economy.unit(g, ante_base)
  return math.max(1, math.floor(Economy.ante_base(g, ante_base) * 0.02 + 0.5))
end

function Economy.margin(base, bonus)
  local bounded_bonus = math.max(-Economy.DEFAULT_MARGIN, math.min(Economy.MAX_MARGIN_BONUS, bonus or 0))
  return math.max(0, math.min(Economy.MAX_MARGIN, (base or Economy.DEFAULT_MARGIN) + bounded_bonus))
end

function Economy.payroll_due(g, founders)
  local salary = 0
  for _, card in ipairs(founders or {}) do
    local cfg = card.ability and card.ability.config or {}
    local effective_salary = cfg._salary
    if effective_salary == nil then
      effective_salary = (card.center and card.center.salary) or 0
      if cfg._distilled then effective_salary = effective_salary * 0.5 end
    end
    salary = salary + effective_salary * (cfg._rental_salary_mult or 1)
  end
  local target = g and g.blind and g.blind.target or 0
  local due = salary * target / Economy.SALARY_DIV
  local event = g and g.blind and g.blind.event
  if event then due = due * require("game.bosses").payroll_multiplier(event) end
  due = due - ((g and g.salary_relief) or 0) - ((g and g.passive_salary) or 0)
  return math.max(0, math.floor(due + 0.5))
end

function Economy.operating_income(g, arr, base_margin)
  local margin = Economy.margin(base_margin, g and g.margin_bonus)
  return math.max(0, math.floor(margin * math.max(0, arr or 0) + 0.5)), margin
end

function Economy.interest(cash, max_payout)
  if (cash or 0) <= 0 then return 0 end
  return math.min(math.floor(cash / Economy.INTEREST_DIV), max_payout or 5)
end

function Economy.early_close_reward(g, ante_base)
  local left = math.max(0, (g and g.ships_left) or 0)
  return left * Economy.unit(g, ante_base)
end

function Economy.raise_terms(g)
  local raises = (g and g.raises_taken) or 0
  local equity_cost = math.min(20, 10 + raises * 2)
  local cash_fraction = math.max(0.10, 0.20 - raises * 0.02)
  return equity_cost, cash_fraction
end

function Economy.ipo_value(g)
  return math.floor(((g and g.valuation) or 0) * (((g and g.equity_pct) or 0) / 100) + 0.5)
end

return Economy
