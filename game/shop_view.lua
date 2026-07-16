-- Pure Shop product-stage geometry.  Drawing, pointer targets, and focus all consume these rectangles.

local ShopView = {}

local function rect(x, y, w, h) return { x = x, y = y, w = w, h = h } end

function ShopView.layout(snapshot, width, height)
  snapshot = snapshot or { offers = {}, capacity = {} }
  width, height = width or 1280, height or 800
  local play_x, right, gap = 352, width - 20, 10
  local available = right - play_x
  local founders = (snapshot.offers and snapshot.offers.founders) or {}
  local founder_slots = math.max(#founders,
    snapshot.capacity and snapshot.capacity.founders and snapshot.capacity.founders.offer_slots or 0)
  local product_count = math.max(1, founder_slots + 1) -- Roadmap is the attached final product.
  local card_w = math.max(104, math.min(142,
    math.floor((available - gap * (product_count - 1)) / product_count)))
  local card_h = math.floor(card_w * 206 / 160 + 0.5)
  local shelf_w = product_count * card_w + (product_count - 1) * gap
  local shelf_x, shelf_y = play_x + math.max(0, (available - shelf_w) / 2), 304

  local voucher_product = rect(play_x + (available - 520) / 2, shelf_y + card_h + 48, 520, 56)
  local out = {
    actions = {
      status = rect(28, 286, 276, 78),
      reroll = rect(28, 376, 276, 48),
      next_blind = rect(28, 434, 276, 54),
    },
    primary = { founders = {}, roadmap = nil },
    voucher = {
      product = voucher_product,
      control = rect(voucher_product.x + voucher_product.w - 108,
        voucher_product.y + 12, 96, 32),
    },
    packs = {},
    drawer_toggle = rect(play_x, 260, 150, 34),
  }
  for index = 1, founder_slots do
    local x = shelf_x + (index - 1) * (card_w + gap)
    out.primary.founders[index] = {
      product = rect(x, shelf_y, card_w, card_h),
      control = rect(x + 8, shelf_y + card_h + 7, card_w - 16, 32),
    }
  end
  local roadmap_x = shelf_x + founder_slots * (card_w + gap)
  out.primary.roadmap = {
    product = rect(roadmap_x, shelf_y, card_w, card_h),
    control = rect(roadmap_x + 8, shelf_y + card_h + 7, card_w - 16, 32),
  }

  local packs = (snapshot.offers and snapshot.offers.packs) or {}
  local pack_count = #packs
  if pack_count > 0 then
    local pack_gap = 12
    local pack_y = voucher_product.y + voucher_product.h + 12
    local max_pack_h = math.max(80, height - pack_y - 16)
    local pack_w = math.min(140, math.floor(max_pack_h * 256 / 342),
      math.floor((available - pack_gap * math.max(0, pack_count - 1)) / pack_count))
    local pack_h = math.floor(pack_w * 342 / 256 + 0.5)
    local total = pack_count * pack_w + math.max(0, pack_count - 1) * pack_gap
    local x0 = play_x + math.max(0, (available - total) / 2)
    local y = pack_y
    for index = 1, pack_count do
      local x = x0 + (index - 1) * (pack_w + pack_gap)
      out.packs[index] = {
        product = rect(x, y, pack_w, pack_h),
        control = rect(x + 4, y + pack_h - 36, pack_w - 8, 32),
      }
    end
  end
  return out
end

return ShopView
