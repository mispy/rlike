#!/usr/bin/env ruby

require 'libtcod'
require 'json'
require 'pry'
require 'active_support/core_ext'
require 'matrix'

require 'asset'

$debug = true
$debug_fov = false

#actual size of the window
SCREEN_WIDTH = 100
SCREEN_HEIGHT = 60

LIMIT_FPS = 20  #20 frames-per-second maximum

MAX_MAP_CREATURES = 20

Console = TCOD::Console.root

def debug(*args)
  puts args.map(&:to_s).join(' ')
end

module Boolean; end
class TrueClass; include Boolean; end
class FalseClass; include Boolean; end

def render_color(color)
  [:r, :g, :b].map { |c| [color[c]+1, 255].min.chr }.join
end

def colorify(s)
  s = s.gsub('{stop}', TCOD::COLCTRL_STOP.chr)
  s = s.gsub(/{bg:(.+?)}/) { |match|
    color = TCOD::Color.const_get(match.gsub('{bg:', '').gsub('}', '').upcase)
    "#{TCOD::COLCTRL_BACK_RGB.chr}#{render_color(color)}"
  }
  s = s.gsub(/{fg:(.+?)}/) { |match|
    color = TCOD::Color.const_get(match.gsub('{fg:', '').gsub('}', '').upcase)
    "#{TCOD::COLCTRL_FORE_RGB.chr}#{render_color(color)}"
  }
end

class Bitfield
  # Just an array of booleans for now, but
  # here so it can be optimized later
  def initialize(w, h)
    @arr = []
    0.upto(w-1) do |x|
      @arr.push([])
      0.upto(h-1) do |y|
        @arr[x].push(false)
      end
    end
  end

  def [](x)
    @arr[x]
  end

  def []=(x, y)
    @arr[x] = y
  end
end

class Cell
  attr_reader :x, :y
  attr_accessor :contents, :terrain

  def initialize(x, y, terrain)
    @x = x
    @y = y
    @terrain = Terrain[terrain] # Basic terrain: wall or floor etc
    @contents = [] # Containing objects
  end

  def find(objtype)
    @contents.find { |x| x.is_a? objtype }
  end

  def creatures
    @contents.find_all { |x| x.is_a? Creature }
  end

  def passable?
    @terrain.passable && !@contents.find { |thing| !thing.passable }
  end

  def put(obj)
    obj.cell.contents.delete(obj) if obj.cell
    obj.cell = self
    @contents.push(obj)
  end

  def distance_to(obj)
    Math.sqrt((obj.x - @x)**2 + (obj.y - @y)**2)
  end

  # List all immediately adjacent cells
  def adjacent
    a = []
    (@x-1 .. @x+1).each do |x|
      (@y-1 .. @y+1).each do |y|
        cell = $map[x][y]
        if cell && cell != self
          a.push cell
        end
      end
    end
    a
  end

  # Directional lookup
  def up; $map[@x][@y-1]; end
  def down; $map[@x][@y+1]; end
  def left; $map[@x-1][@y]; end
  def right; $map[@x+1][@y]; end

  def burn
    @terrain = Terrain[:charcoal] if @terrain.passable
  end

  def freeze
    @terrain = Terrain[:ice] if @terrain.passable
  end
end

class Template
  class << self
    def [](type)
      @instances ||= {}
      @instances[type] or raise ArgumentError, "No such #{self.name}: #{type.inspect}"
    end

    def []=(type, val)
      @instances ||= {}
      @instances[type] = val
    end
  end

  attr_reader :label # Label for an instance of a template

  def self.one(*fields)
    fields.each { |field| attr_reader field }
  end
end

class Terrain < Template
  FLAG_FLAMMABLE = :flammable

  one :name, :char, :color, :bg_color, :passable, :flags

  def is(flag)
    @flags.include?(flag)
  end
end

class Species < Template
  one :name, :char, :color, :fov_range, :base_hp
end

class Projectile
  def initialize(opts)
    @path = opts[:path]
    @char = opts[:char]
    @colors = opts[:colors]
    @position = 0
  end

  def impact(cell)
    @on_impact.call(cell)
    $game.projectiles.delete(self)
  end

  def on_impact(&block)
    @on_impact = block
  end

  def render(con)
    cell = @path[@position]
    con.put_char(cell.x, cell.y, @char)
    color = @colors[@position % @colors.length]
    con.set_char_background(cell.x, cell.y, color)

    if cell == @path[-1] || !cell.terrain.passable
      impact(cell)
    else
      @position += 1
    end
  end
end

class Animation
  def initialize(opts, &block)
    @duration = opts[:duration]
    @block = block
    @frame = 0
  end

  def render(con)
    @block.call(con, @frame)
    @frame += 1

    if @duration && @frame >= @duration
      $game.anims.delete(self)
    end
  end
end

class Effect
  def self.apply(effect, cells, user, ability)
    if effect.type == :damage
      cells.each do |cell|
        cell.creatures.each do |cre|
          next unless $player.dislikes?(cre)
          color = $player.likes?(cre) ? 'red' : 'green'
          $log.write("{fg:#{color}}#{cre.name} takes #{effect.amount} damage from #{user.name}'s #{ability.name}{stop}")
          cre.take_damage(effect.amount, self)
        end
      end
    elsif effect.type == :burn
      cells.each(&:burn)
    elsif effect.type == :freeze
      cells.each(&:freeze)
    end
  end
end

class Ability < Template
  TARGET_SELF = :self
  TARGET_LINE = :line
  TARGET_WAVE = :wave
  TARGET_PROJECTILE = :projectile
  TARGET_VORTEX = :vortex

  one :name, :key, :targets, :colors, :projectile

  def color; @color||@colors[0]; end

  def invoke(user, tcell)
    if @projectile
      projectile = Projectile.new(
        char: @projectile.char,
        colors: @colors,
        path: $map.line_between(user, tcell).to_a[1..-1]
      )
      projectile.on_impact do |cell|
        cells = $map.circle_around(cell, @projectile.impact_radius)
        anim = Animation.new(duration: 5) do |con, frame|
          cells.each do |c|
            color = @colors[frame % @colors.length]
            con.put_char(c.x, c.y, '*')
            con.set_char_background(c.x, c.y, color)
          end
        end

        @projectile.impact_effects.each do |effect|
          Effect.apply(effect, cells, user, self)
        end

        $game.anims.push(anim)
      end
      $game.projectiles.push(projectile)

    else
      cells = target(user, tcell)
      anim = Animation.new(duration: 5) do |con, frame|
        j = frame
        cells.each do |c|
          color = @colors[j % @colors.length]
          con.set_char_background(c.x, c.y, color)
          j += 1
        end
      end
      $game.anims.push(anim)

      @effects.each do |effect|
        Effect.apply(effect, cells, user, self)
      end
    end
  end

  def target(source, cell)
    cells = []

    case @targets
    when TARGET_LINE
      $map.line_between(source, cell).to_a[1..-1].each do |c|
        cells << c
        break unless c.terrain.passable
      end
    when TARGET_WAVE
      $map.wave_between(source, cell).to_a[1..-1].each do |c|
        cells << c
      end
    when TARGET_PROJECTILE
      target = cell
      $map.line_between(source, cell).to_a[1..-1].each do |c|
        cells << c
        unless c.terrain.passable
          target = c
          break
        end
      end
      $map.circle_around(target, 5).each do |c|
        cells << c
      end
    when TARGET_VORTEX
      cells = $map.vortex_towards(source, cell)
    end

    cells
  end
end

class DamageEffect
  def initialize(opts)
    @amount = opts[:amount]
  end
end

class Anim
  def initialize(&block)
    @block = block
  end

  def render(con)
    self.instance_exec(con, &@block)
  end

  def end_anim
    $game.anims.delete(self)
  end
end

# Represents a rectangular subdivision of a map
# Used for binary space partitioning
class Div
  attr_reader :x1, :y1, :x2, :y2, :w, :h, :cx, :cy
  def initialize (map, x, y, w, h)
    @map = map
    @x1 = x
    @y1 = y
    @x2 = x + w
    @y2 = y + h
    @w = w
    @h = h
    @cx = ((@x1 + @x2) / 2).floor
    @cy = ((@y1 + @y2) / 2).floor

    if @x1 <= 0 || @y1 <= 0 || @x2 >= @map.width || @y2 >= @map.height
      debug @map.width, @map.height
      raise ArgumentError, "Subdivision exceeds map bounds: #{@x1} #{@y1} #{@x2} #{@y2}"
    end
  end

  def [](x)
    @map[@x1+x][@y1..@y2]
  end

  def size
    @w*@h
  end

  def intersect (other)
    return (@x1 <= other.x2 and @x2 >= other.x1 and
      @y1 <= other.y2 and @y2 >= other.y1)
  end

  def split_vertical(h)
    [Div.new(@map, @x1, @y1, @w, h),
     Div.new(@map, @x1, @y1+h+1, @w, @h-h-1)]
  end

  def split_horizontal(w)
    [Div.new(@map, @x1, @y1, w, @h),
     Div.new(@map, @x1+w+1, @y1, @w-w-1, @h)]
  end

  def subdiv(x, y, w, h)
    Div.new(@map, @x1+x, @y1+y, w, h)
  end

  def fill(terrain)
    (0 ... @w).each do |x|
      (0 ... @h).each do |y|
        self[x][y].terrain = Terrain[terrain]
      end
    end
  end

  def paint_room
    w = [rand(@w-2), 3].max
    h = [rand(@h-2), 3].max
    x1 = 1+rand(@w-w)
    y1 = 1+rand(@h-h)

    subdiv(x1, y1, w, h).fill(:grass)
  end

  def paint_oval
    center = @map[@cx][@cy]
    rh = @h/2
    rw = @w/2
    cells.each do |cell|
      if rw < rh
        if (cell.x - @cx).abs < rw && cell.distance_to(center) < rh
          cell.terrain = Terrain[:grass]
        end
      else
        if (cell.y - @cy).abs < rh && cell.distance_to(center) < rw
          cell.terrain = Terrain[:grass]
        end
      end
    end
  end

  def cells(&b)
    Enumerator.new do |ys|
      (0 ... @w).each do |x|
        self[x].each do |cell|
          ys << cell
        end
      end
    end
  end

  def some_passable_cell
    cells.find_all { |cell| cell.passable? }.sample
  end
end

class Range
  def sample
    min + rand(max-min)
  end
end

class Mapgen
  def solid_base(width, height)
    map = Map.new(width, height)
    map.instance_eval do
      0.upto(width-1) do |x|
        @cellmap.push([])
        0.upto(height-1) do |y|
          @cellmap[x].push(Cell.new(x, y, :wall))
        end
      end
    end
    map
  end

  def paint_htunnel(x1, x2, y)
    ([x1,x2].min .. [x1,x2].max).each do |x|
      @map[x][y].terrain = Terrain[:grass]
    end
  end

  def paint_vtunnel(y1, y2, x)
    ([y1,y2].min .. [y1,y2].max).each do |y|
      @map[x][y].terrain = Terrain[:grass]
    end
  end

  def paint_stairs
    @map.some_passable_cell.contents.push(Staircase.new(:down))
    @map.some_passable_cell.contents.push(Staircase.new(:up))
  end

  def classic(width, height, opts={})
    opts = {
      max_rooms: 10,
      room_min_size: 6,
      room_max_size: 10
    }.merge(opts)

    @map = solid_base(width, height)

    rooms = []

    0.upto(opts[:max_rooms]) do
      w = (opts[:room_min_size] .. opts[:room_max_size]).sample
      h = (opts[:room_min_size] .. opts[:room_max_size]).sample
      x = (0 .. @map.width - w - 1).sample
      y = (0 .. @map.height - h - 1).sample

      new_room = Rect.new(x, y, w, h)
      next if rooms.find { |other| new_room.intersect(other) }

      paint_room(new_room)
      new_x, new_y = new_room.center

      # Connect to any previous room
      unless rooms.empty?
        prev_x, prev_y = rooms[-1].center

        if rand < 0.5
          paint_htunnel(prev_x, new_x, prev_y)
          paint_vtunnel(prev_y, new_y, new_x)
        else
          paint_vtunnel(prev_y, new_y, prev_x)
          paint_htunnel(prev_x, new_x, new_y)
        end
      end

      rooms.push(new_room)
      prev_x, prev_y = new_x, new_y
    end

    paint_stairs
    @map
  end

  def partition_map
    divs = [Div.new(@map, 1, 1, @map.width-2, @map.height-2)]

    loop do
      new_divs = []
      split = false
      divs.each do |div|
        if div.size <= 10000
          new_divs.push(div)
        else
          split = true
          if div.w > div.h
            w = [[rand(div.w), 6].max, div.w-6].min
            new_divs += div.split_horizontal(w)
          else
            h = [[rand(div.w), 6].max, div.h-6].min
            new_divs += div.split_vertical(h)
          end
        end
      end
      break unless split
      divs = new_divs
    end

    divs
  end

  def paint_path(path, terrain)
    path.each do |x, y|
      @map[x][y].terrain = Terrain[terrain]
    end
  end

  def paint_tunnel(x1, y1, x2, y2)
    if rand < 0.5
      paint_htunnel(x1, x2, y1)
      paint_vtunnel(y1, y2, x2)
    else
      paint_vtunnel(y1, y2, x1)
      paint_htunnel(x1, x2, y2)
    end
  end

  def bsp(width, height)
    @map = solid_base(width, height)

    divs = partition_map

    divs.each do |div|
      div.paint_oval
    end

    last_div = divs[0]
    divs[1..-1].each do |div|
      c1 = last_div.some_passable_cell
      c2 = div.some_passable_cell
      paint_tunnel(c1.x, c1.y, c2.x, c2.y)
      last_div = div
    end

=begin
    prev_room = nil
    rooms.each do |room|
      paint_room(room)

      if prev_room
        new_x, new_y = room.center
        prev_x, prev_y = prev_room.center

        if rand < 0.5
          paint_htunnel(prev_x, new_x, prev_y)
          paint_vtunnel(prev_y, new_y, new_x)
        else
          paint_vtunnel(prev_y, new_y, prev_x)
          paint_htunnel(prev_x, new_x, new_y)
        end
      end

      prev_room = room
    end
=end

    paint_stairs
    @map
  end
end

$mapgen = Mapgen.new

class Map
  attr_reader :width, :height, :cells, :tcod_map
  def initialize(w, h)
    @width = w
    @height = h
    @cellmap = []

    @tcod_map = nil
  end

  def precompute
    @tcod_map = TCOD::Map.new(@width, @height)
    cells.each do |cell|
      @tcod_map.set_properties(cell.x, cell.y, cell.passable?, cell.passable?)
    end
  end

  def creatures
    cells.map { |cell| cell.contents.find_all { |obj| obj.is_a? Creature } }.flatten
  end

  def path_between(cell1, cell2, &b)
    if b
      path = TCOD::Path.by_callback(@width, @height, &b)
    else
      path = TCOD::Path.by_map(@tcod_map, 1.41)
    end

    if path.compute(cell1.x, cell1.y, cell2.x, cell2.y)
      path
    else
      nil
    end
  end

  # Returns a list of cells in a line between cell1 and cell2
  def line_between(cell1, cell2)
    # Bresenham's line algorithm
    # http://en.wikipedia.org/wiki/Bresenham's_line_algorithm
    x0, y0, x1, y1 = cell1.x, cell1.y, cell2.x, cell2.y
    dx = (x1-x0).abs
    dy = (y1-y0).abs
    sx = (x0 < x1 ? 1 : -1)
    sy = (y0 < y1 ? 1 : -1)
    err = dx-dy

    Enumerator.new do |cells|
      loop do
        cells << $map[x0][y0] if $map[x0][y0]
        break if x0 == x1 && y0 == y1
        e2 = 2*err
        if e2 > -dy
          err = err - dy
          x0 += sx
        end
        if x0 == x1 && y0 == y1
          cells << $map[x0][y0] if $map[x0][y0]
          break
        end
        if e2 < dx
          err = err + dx
          y0 += sy
        end
      end
    end
  end

  # Returns an array of cells constituting a spreading wave
  # between cell1 and cell2
  def wave_between(cell1, cell2)
    Enumerator.new do |cells|
      i = 0
      line_between(cell1, cell2).each do |cell|
        if (cell2.x-cell1.x).abs > (cell2.y-cell1.y).abs
          sides = [(cell.y ... cell.y+i), (cell.y-i ... cell.y).to_a.reverse]
          sides.each do |side|
            side.each do |y|
              target = $map[cell.x][y]
              cells << target if target
              break unless target && target.terrain.passable
            end
          end
        else
          sides = [(cell.x ... cell.x+i), (cell.x-i ... cell.x).to_a.reverse]
          sides.each do |side|
            side.each do |x|
              target = $map[x][cell.y]
              cells << target if target
              break unless target && target.terrain.passable
            end
          end
        end

        break unless cell.terrain.passable
        i += 1
      end
    end
  end

  def circle_around(cell, radius)
    Enumerator.new do |cells|
      (cell.x-radius ... cell.x+radius).each do |x|
        (cell.y-radius ... cell.y+radius).each do |y|
          if $map[x][y].distance_to(cell) <= radius
            cells << $map[x][y] if $map[x][y]
          end
        end
      end
    end
  end

  def ring_around(center, radius)
    cells = []

    add_cell = proc { |cell|
      if cell
        dist = cell.distance_to(center)
        if dist.round == radius
          cells << cell unless cells.include?(cell)
        end
      end
    }

    (center.x-radius ... center.x).each do |x|
      (center.y-radius ... center.y).each do |y|
        add_cell.call($map[x][y])
      end
    end

    (center.x .. center.x+radius).each do |x|
      (center.y-radius .. center.y).each do |y|
        add_cell.call($map[x][y])
      end
    end

    (center.x .. center.x+radius).to_a.reverse.each do |x|
      (center.y .. center.y+radius).each do |y|
        add_cell.call($map[x][y])
      end
    end

    (center.x-radius .. center.x).to_a.reverse.each do |x|
      (center.y .. center.y+radius).each do |y|
        add_cell.call($map[x][y])
      end
    end

    cells
  end

  def spiral_around(cell, radius)

    cells = []

    x, y = 0, 0
    dx, dy = 0, -1

    0.upto(radius**2) do
      cx, cy = cell.x+x, cell.y+y
      cells << $map[cx][cy] if $map[cx][cy]

      if x == y || (x < 0 && x == -y) || (x > 0 && x == 1-y)
        dx, dy = -dy, dx
      end

      if (x < 0 && x == -y)
        x, y = x+dy, y+dx
      end

      x, y = x+dx, y+dy
    end

    cells
  end

  def spiral_towards(source, cell)
    cells = []
    i = 0
    $map.line_between(source, cell).each_slice(3) do |c, _|
      ring = $map.ring_around(c, 3)
      cells += ring#.rotate(i)[0..ring.length-5]
      i += 3
    end
    cells
  end

  def vortex_towards(source, cell, radius=5)
    return [] if source.distance_to(cell) < 1
    v = Vector[cell.x - source.x, cell.y - source.y].normalize
    pv1 = Vector[-v[1], v[0]]
    pv2 = Vector[v[1], -v[0]]

    cells = []

    r = 0
    dr = 1

    $map.line_between(source, cell).each do |c|
      r += dr
      if r == radius
        dr = -1
      elsif r == -radius
        dr = 1
      end

      pvv1 = pv1*r
      pvv2 = pv2*r

      c2 = $map[c.x+pvv1[0]][c.y+pvv1[1]]
      c3 = $map[c.x+pvv2[0]][c.y+pvv2[1]]
      cells += $map.circle_around(c2, 1).to_a if c2 && c2.terrain.passable
      cells += $map.circle_around(c3, 1).to_a if c3 && c3.terrain.passable
      break unless c.terrain.passable
    end
    cells
  end

  def [](x)
    @cellmap[x] || []
  end

  def cells(&b)
    Enumerator.new do |y|
      @cellmap.each do |row|
        row.each do |cell|
          y << cell
        end
      end
    end
  end

  def upstair
    cells.find { |cell| cell.contents.find { |c| c.is_a?(Staircase) && c.dir == :up } }
  end

  def downstair
    cells.find { |cell| cell.contents.find { |c| c.is_a?(Staircase) && c.dir == :down } }
  end

  def some_passable_cell
    cells.find_all { |cell| cell.passable? }.sample
  end

  def some_cell
    @cellmap[rand(@width)][rand(@height)]
  end

  def things
    cells.map { |cell| cell.contents }.flatten
  end
end

class Thing
  attr_accessor :char, :color, :passable
  attr_accessor :cell

  def initialize
    @char = '?'
    @color = TCOD::Color::PINK
    @passable = true

    @cell = nil
  end

  def x; @cell.x; end
  def y; @cell.y; end

  def take_turn; end
end

module Mind
  STATE_IDLE = :idle
  STATE_MOVING = :moving
  STATE_FOLLOWING = :following
  STATE_ATTACKING = :attacking

  attr_accessor :path # Path we are walking
  attr_accessor :attacking # Target Creature for STATE_ATTACKING
  attr_accessor :following # Target Creature for STATE_FOLLOWING

  def init_mind
    @mind_state = STATE_IDLE
  end

  def random_walk
    move_to(@cell.adjacent.sample)
  end

  def nearby_enemy
    $map.creatures.find do |cre|
      dislikes?(cre) && can_see?(cre)
    end
  end

  def take_turn
    case @mind_state
    when STATE_IDLE
      if (target = nearby_enemy)
        order_attack(target)
        return take_turn
      end

      random_walk

    when STATE_FOLLOWING
      if false#(target = nearby_enemy)
        order_attack(target)
        return take_turn
      end

      unless walk_path
        @path = path_to(@following)
        walk_path
      end

    when STATE_MOVING
      if (target = nearby_enemy)
        order_attack(target)
        return take_turn
      end

      unless walk_path
        @mind_state = STATE_IDLE
      end

    when STATE_ATTACKING
      #if @cell.distance_to(@attacking) < 5
      #  $log.write "#{name} damages #{@attacking.name} #{@attacking.hp}/#{@attacking.max_hp}"
      #  @attacking.take_damage(1, self)
      #else
        @path = path_to(@attacking) unless walk_path
      #end
    end
  end

  def change_mind(state)
    @path = nil
    @following = nil
    @attacking = nil
    @mind_state = state
  end

  ### Orders

  def order_follow(target)
    change_mind(STATE_FOLLOWING)
    @following = target
  end

  def order_move(cell)
    change_mind(STATE_MOVING)
    @path = path_to(cell)
  end

  def order_attack(target)
    change_mind(STATE_ATTACKING)
    @attacking = target
  end

  def order_burrow(cell)
    @burrowing = true
    @path = path_to(cell, true)
  end
end

class Creature < Thing
  attr_accessor :tamer, :pets, :memory_map
  attr_accessor :fov_map, :fov_range
  attr_accessor :type, :name, :template, :char, :color
  attr_accessor :mind_state
  attr_accessor :hp, :max_hp
  attr_accessor :abilities

  include Mind

  def initialize(type)
    super()
    @passable = false # No known Creature is passable.

    @tamer = nil # Empath we are bound to (currently always the player)
    @pets = [] # Pets we are bound to (currently player-only)
    @memory_map = nil # Memory map bitfield (currently player-only)

    @fov_map = nil # TCOD data structure for pet/player FOV calcs.

    @type = type
    @template = Species[@type]
    @name = @template.name
    @char = @template.char
    @color = @template.color
    @fov_range = @template.fov_range
    @max_hp = @template.base_hp
    @hp = @template.base_hp

    @abilities = []

    init_mind
  end

  # Willful (and therefore blockable) movement
  # Returns false if movement was impossible
  def move_to(cell)
    return false unless cell.terrain.passable # Can't cross unpassable terrain

    displace = nil
    cell.contents.each do |obj|
      if !obj.passable
        if can_displace?(obj)
          displace = obj # Swap positions with a pet
        else
          return false
        end
      end
    end

    @cell.put(displace) if displace
    cell.put(self)
  end

  # Test for a pet/tamer relationship
  def bound_to?(obj)
    @tamer == obj || obj.tamer == self
  end

  # Test for ability to swap positions
  def can_displace?(obj)
    obj.is_a?(Creature) && @pets.include?(obj)
  end

  def burrow(x, y)
    target = $map[x][y]
    target.terrain = Terrain[:grass]
    target.put(self)
  end

  def turn_burrowing
    if @path.empty?
      @burrowing = false
      take_turn
    else
      x, y = @path.walk
      burrow(x, y)
    end
  end

  def walk_path
    if @path.nil? || @path.empty?
      false
    else
      x, y = @path.walk
      move_to($map[x][y])
      true
    end
  end

  def take_pet_turn
  end

  def can_see?(obj)
    @cell.distance_to(obj) < @fov_range
  end

  def likes?(obj)
    if $player.and_pets.include?(self)
      $player.and_pets.include?(obj)
    else
      !$player.and_pets.include?(obj)
    end
  end

  def dislikes?(obj)
    !likes?(obj)
  end

  def take_wild_turn
    return walk_path if @path

    target = $map.creatures.find do |cre|
      dislikes?(cre) && can_see?(cre)
    end

    if target
      @path = path_to(target.cell)
    else
      random_walk
    end
  end

  def path_to(target, burrow=false)
    if burrow
      $map.path_between(@cell, target) { 1.0 }
    else
      $map.path_between(@cell, target)
    end
  end

  def take_damage(amount, source)
    @hp -= amount
    if @hp <= 0
      color = $player.likes?(self) ? 'red' : 'green'
      $log.write("{fg:#{color}}#{name} is defeated!{stop}")
      @cell.contents.delete(self)

      $map.creatures.each do |cre|
        if cre.attacking == self
          cre.attacking = nil
          cre.mind_state = Mind::STATE_IDLE
        end

        if cre.following == self
          cre.following = nil
          cre.mind_state = Mind::STATE_IDLE
        end
      end
    end
  end

  ### Debug

  def to_s
    "<Creature :#{@type} (#{x},#{y})>"
  end

  def distance_to(*args)
    @cell.distance_to(*args)
  end
end

class Player < Creature
  def initialize
    super(:player)
  end

  def summon_pets
    i = 0
    cells = @cell.adjacent.find_all { |x| x.passable? }
    cells = cells.sample(cells.length)
    @pets.each_with_index do |pet, i|
      cells[i].put(pet)
    end
  end

  def and_pets
    [self]+@pets
  end

  def take_turn; end
end

class Staircase < Thing
  attr_reader :dir

  def initialize(dir)
    super()
    @dir = dir
    @char = @dir == :up ? '<' : '>'
    @color = TCOD::Color::WHITE
  end

  def activate
    $game.change_map($mapgen.bsp(SCREEN_WIDTH, SCREEN_HEIGHT))
    opposite = (@dir == :down ? :up : :down)
    cell = $map.cells.find { |c| c.contents.find { |obj| obj.is_a?(Staircase) && obj.dir == opposite } }
    cell.put($player)
    $player.summon_pets
  end
end


class Game
  attr_accessor :log, :anims, :projectiles

  def initialize
    $player = Player.new
    $player.name = 'Mispy'
    pyromouse = Creature.new(:pyromouse)
    pyromouse.abilities = [Ability[:firewave], Ability[:fireball]]
    cryobeetle = Creature.new(:cryobeetle)
    cryobeetle.abilities = [Ability[:frostray]]

    [pyromouse, cryobeetle].each do |pet|
      pet.tamer = $player
      $player.pets.push(pet)
      pet.order_follow($player)
    end

    change_map($mapgen.bsp(SCREEN_WIDTH, SCREEN_HEIGHT))
    $map.upstair.put($player)
    $player.summon_pets

    $log = MessageLog.new
    $log.messages.push("Hullo there!")

    $map.some_passable_cell.put(Creature.new(:gridbug))
    $map.some_passable_cell.put(Creature.new(:gridbug))
    $map.some_passable_cell.put(Creature.new(:gridbug))
    $map.some_passable_cell.put(Creature.new(:gridbug))
    $map.some_passable_cell.put(Creature.new(:gridbug))
    $map.some_passable_cell.put(Creature.new(:gridbug))
    $map.some_passable_cell.put(Creature.new(:gridbug))

    @anims = []
    @projectiles = []
  end

  def change_map(new_map)
    $map = new_map

    $map.precompute

    $player.memory_map = Bitfield.new($map.width, $map.height)
    $player.and_pets.each do |cre|
      cre.fov_map = $map.tcod_map.clone
    end
  end

  def end_turn
    $map.things.each do |thing|
      thing.take_turn
    end

    if rand < 0.01 && $map.downstair.passable? && $map.creatures.length < MAX_MAP_CREATURES
      $map.downstair.put(Creature.new(:gridbug))
    end
  end

  def start
    until Console.window_closed?
      begin
        $ui.render
        Console.flush

        TCOD.sys_check_for_event(TCOD::EVENT_KEY_PRESS | TCOD::EVENT_MOUSE, $key, $mouse)

        if $key.vk != TCOD::KEY_NONE
          exit! if $key.lctrl && $key.c == 'c'
          $ui.on_keypress($key)
        elsif $mouse.lbutton_pressed
          $ui.on_lclick
        end
      rescue Exception => e
        debug $!.inspect
        debug e.backtrace.join("\n\t")
      end
    end
  end
end

class MessageLog
  attr_accessor :messages

  def initialize
    @messages = []
  end

  def write(msg)
    @messages.push(msg)
  end

  def render(console, x, y, width, height)
    con = TCOD::Console.new(width, height)

    start = [0, @messages.length-height].max

    @messages.from(start).each_with_index do |msg, i|
      con.print_rect(0, i, width, height, colorify(msg))
    end

    console.blit(con, 0, 0, width, height, x, y)
  end
end


class MainGameUI
  STATE_MAIN = :main
  STATE_LOG = :show_log # Viewing the full message log
  STATE_CHOOSE_ORDER = :choose_order # Pet selected
  STATE_TARGET_ABILITY = :target_ability # Pet and ability selected

  ORDER_MOVE = :move
  ORDER_FOLLOW = :follow
  ORDER_ATTACK = :attack

  def initialize
    @pet = nil # Selected pet
    @burrowing = false
    @state = STATE_MAIN
  end

  def select_pet(pet)
    @state = STATE_CHOOSE_ORDER
    @pet = pet
  end

  # Render the visible structure and contents of the map
  def render_map(con)
    $player.and_pets.each do |cre|
      cre.fov_map.compute_fov(cre.x, cre.y, cre.fov_range, true, 0)
    end

    $map.cells.each do |cell|
      if $debug_fov
        visible = true
      else
        visible = false
        $player.and_pets.each do |cre|
          if cre.fov_map.in_fov?(cell.x, cell.y)
            visible = true; break
          end
        end
      end

      remembered = $player.memory_map[cell.x][cell.y]
      terrain = cell.terrain
      obj = cell.contents[-1] || terrain

      if visible
        $player.memory_map[cell.x][cell.y] = true
        if obj == @pet || (cell.x == $mouse.cx && cell.y == $mouse.cy)
          con.put_char_ex(cell.x, cell.y, obj.char, obj.color, TCOD::Color::WHITE)
        else
          con.put_char_ex(cell.x, cell.y, obj.char, obj.color, terrain.bg_color)
        end
      elsif remembered
        obj = cell.contents.find { |o| !o.is_a? Creature } || cell.terrain
        con.put_char_ex(cell.x, cell.y, obj.char, obj.color * 0.5, terrain.bg_color * 0.5)
      else
        con.put_char(cell.x, cell.y, ' ', TCOD::BKGND_NONE)
      end
    end

    # Miscellaneous animations
    $game.anims.each do |anim|
      anim.render(con)
    end

    $game.projectiles.each do |proj|
      proj.render(con)
    end
  end

  # Render the pet status/selection sidebar
  def render_sidebar(con)
    if [STATE_CHOOSE_ORDER, STATE_TARGET_ABILITY].include?(@state)
      sidebar = "{bg:white}{fg:black}[#{$player.pets.index(@pet)+1}] #{@pet.name}{stop}\n"
      sidebar += "Awaiting orders\n"
      @pet.abilities.each do |ability|
        if @ability == ability
          sidebar += "{bg:white}{fg:black}[#{ability.key}] #{ability.name}{stop}\n"
        else
          sidebar += "[#{ability.key}] #{ability.name}\n"
        end
      end
    else
      sidebar = "#{$player.name}\n"
      $player.pets.each_with_index do |pet, i|
        sidebar += "[#{i+1}] #{pet.name}\n"
        sidebar += describe_behavior(pet) + "\n"
      end
    end

    con.print_rect(0, 0, SCREEN_HEIGHT, 10, colorify(sidebar))
  end

  # Render the dynamic attack/move/follow order path
  def render_order_path(con)
    cell = $map[$mouse.cx][$mouse.cy]
    if (target = cell.creatures.find { |cre| @pet.dislikes?(cre) })
      @order = ORDER_ATTACK
      @order_proc = proc { @pet.order_attack(target) }
      @order_desc = "{fg:red}Attack #{target.name}{stop}"
      path_color = TCOD::Color::RED
    elsif (friend = cell.creatures.find { |cre| !@pet.dislikes?(cre) })
      @order = ORDER_FOLLOW
      @order_proc = proc { @pet.order_follow(friend) }
      @order_desc = "{fg:light_blue}Follow #{friend.name}{stop}"
      path_color = TCOD::Color::BLUE
    else
      @order = ORDER_MOVE
      @order_proc = proc { @pet.order_move(cell) }
      @order_desc = "{fg:green}Move here{stop}"
      path_color = TCOD::Color::GREEN
    end

    path = @pet.path_to(cell)
    if path
      path.each { |x, y| con.set_char_background(x, y, path_color) }
    end
  end

  # Render the targeting interface for an ability
  def render_targeter(con)
    cell = $map[$mouse.cx][$mouse.cy]

    @ability.target(@pet, cell).each do |c|
      con.set_char_background(c.x, c.y, @ability.color)
    end

  end

  def render_main
    con = TCOD::Console.new($map.width, $map.height) # Temporary console
    con.set_background_flag(TCOD::BKGND_SET)

    render_map(con)

    if @state == STATE_CHOOSE_ORDER
      render_order_path(con)
    elsif @state == STATE_TARGET_ABILITY
      render_targeter(con)
    end

    render_sidebar(con)
    $log.render(con, 0, SCREEN_HEIGHT-3, SCREEN_WIDTH, 3)

    if @state == STATE_CHOOSE_ORDER
      con.print_ex(SCREEN_WIDTH-1, SCREEN_HEIGHT-2, TCOD::BKGND_DEFAULT, TCOD::RIGHT, colorify(@order_desc))
    else
      # Hover inspect
      cell = $map[$mouse.cx][$mouse.cy]
      if cell.creatures.empty?
        con.print_ex(SCREEN_WIDTH-1, SCREEN_HEIGHT-2, TCOD::BKGND_DEFAULT, TCOD::RIGHT,
                     cell.terrain.name)
      else
        cell.creatures.each do |cre|
          text = "#{cre.name}\n#{describe_behavior(cre)}"
          con.print_ex(SCREEN_WIDTH-1, SCREEN_HEIGHT-2, TCOD::BKGND_DEFAULT, TCOD::RIGHT, colorify(text))
          break
        end
      end
    end

    Console.blit(con, 0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, 0, 0)
  end

  # Produce a string describing a Creature's current behavior
  def describe_behavior(cre)
    case cre.mind_state
    when Mind::STATE_MOVING
      "{fg:green}Moving to position{stop}"
    when Mind::STATE_ATTACKING
      "{fg:red}Attacking #{cre.attacking.name}{stop}"
    when Mind::STATE_FOLLOWING
      "{fg:light_blue}Following #{cre.following.name}{stop}"
    when Mind::STATE_IDLE
      "Idle"
    end
  end

  def render_log
    $log.render(Console, 0, 0, SCREEN_HEIGHT, SCREEN_WIDTH)
  end

  def render
    case @state
    when STATE_MAIN then render_main
    when STATE_CHOOSE_ORDER then render_main
    when STATE_TARGET_ABILITY then render_main
    when STATE_LOG then render_log
    end
  end

  # Handle keypress in state where a pet has been previously
  # assigned to @pet
  def on_pet_keypress(key)
    case key.c
    when ('a'..'z') then
      @pet.abilities.each do |ability|
        if ability.key == key.c
          @ability = ability
          @state = STATE_TARGET_ABILITY
        end
      end
    when 'b' then
      @burrowing = !@burrowing
    when "\r"
      submit_order
    end
  end

  # Handle keypress in main game state
  def on_main_keypress(key)
    # Keypress in main state

    # Debug mode overrides
    if $debug && (key.lalt || key.ralt)
      case key.c
      when 'l' then $log.messages.push("boop"*rand(10))
      when 'f' then $debug_fov = !$debug_fov
      end
    end

    if key.lctrl || key.rctrl
      case key.c
      when 's' then $game.save("save/game.json")
      when 'l' then $game.load("save/game.json")
      end
    end

    case key.c
    when ('1'..'9') then
      select_pet($player.pets[key.c.to_i-1]) unless key.c.to_i > $player.pets.length
    when 'L' then
      @state = STATE_LOG
    when '`' then binding.pry
    when '>'
      $player.cell.contents.each do |obj|
        obj.activate if obj.is_a?(Staircase) && obj.dir == :down
      end
    when '<'
      $player.cell.contents.each do |obj|
        obj.activate if obj.is_a?(Staircase) && obj.dir == :up
      end
    when '.'
      $game.end_turn
    end

    if Console.key_pressed?(TCOD::KEY_UP)
      $player.move_to($player.cell.up)
      $game.end_turn
    elsif Console.key_pressed?(TCOD::KEY_DOWN)
      $player.move_to($player.cell.down)
      $game.end_turn
    elsif Console.key_pressed?(TCOD::KEY_LEFT)
      $player.move_to($player.cell.left)
      $game.end_turn
    elsif Console.key_pressed?(TCOD::KEY_RIGHT)
      $player.move_to($player.cell.right)
      $game.end_turn
    end
  end

  def on_log_keypress(key)
    @state = STATE_MAIN
  end

  def on_keypress(key)
    case @state
    when STATE_MAIN
      on_main_keypress(key)
    when STATE_CHOOSE_ORDER
      on_pet_keypress(key)
    when STATE_LOG then on_log_keypress(key)
    end
  end

  def submit_order
    @order_proc.call
    @pet = nil
    @state = STATE_MAIN
  end

  def on_lclick
    cell = $map[$mouse.cx][$mouse.cy]

    case @state
    when STATE_MAIN
      # Select a pet
      cell.creatures.each do |cre|
        if cre.tamer == $player
          select_pet(cre)
          break
        end
      end
    when STATE_CHOOSE_ORDER
      submit_order if @order
    when STATE_TARGET_ABILITY
      @ability.invoke(@pet, cell)
      @pet = nil
      @state = STATE_MAIN
      $game.end_turn
    end
  end
end

#############################################
# Initialization & Main Loop
#############################################

Console.set_custom_font('arial12x12.png', TCOD::FONT_TYPE_GREYSCALE | TCOD::FONT_LAYOUT_TCOD, 0, 0)
Console.init_root(SCREEN_WIDTH, SCREEN_HEIGHT, 'ruby/TCOD tutorial', false, TCOD::RENDERER_SDL)
TCOD.sys_set_fps(LIMIT_FPS)


class Menu
  def initialize
    @selected = 0
    @options = ['Cute', 'Scary']
  end

  def print(console)
    w, h = console.width, console.height
    console.set_background_flag(TCOD::BKGND_SET)
    console.set_alignment(TCOD::CENTER)

    y = 1
    console.print(w/2, 1, "New Game!")

    @options.each_with_index do |opt, i|
      if @selected == i
        s = "\a\xff\xff\xff\x06\x01\x01\x01" + opt + "\b"
      else
        s = opt
      end
      console.print(w/2, y+=4, s)
    end

    if @selected == 0
      console.print_rect(w/2, y += 4, w-10, h, "In Cute mode, defeat is only temporary. Pets will recover their health and return to battle.")
    end
  end

  def on_keypress(key)
  end
end

trap('SIGINT') { exit! }

=begin
SDL::TTF.init
TCOD::System.register_sdl_renderer do |renderer|
  dst = SDL::Screen.get
  font = SDL::TTF.open('FreeSerif.ttf', 32, 0)
  surface = font.render_solid_utf8("hullo", 255, 255, 255)
  SDL::Surface.blit(surface, 0, 0, 0, 0, dst, 0, 0)
end
=end

$ui = MainGameUI.new
$key = TCOD::Key.new
$mouse = TCOD::Mouse.new
