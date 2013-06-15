#!/usr/bin/env ruby

require 'libtcod'
require 'json'
require 'pry'
require 'active_support/core_ext'

$debug = true
$debug_fov = false

#actual size of the window
SCREEN_WIDTH = 80
SCREEN_HEIGHT = 50
 
LIMIT_FPS = 20  #20 frames-per-second maximum

MAX_MAP_CREATURES = 20

Console = TCOD::Console.root

def debug(*args)
  puts args.map(&:to_s).join(' ')
end

module Boolean; end
class TrueClass; include Boolean; end
class FalseClass; include Boolean; end

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
    @terrain = terrain # Basic terrain: wall or floor etc
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
end

class Template
  class << self
    attr_reader :fields # Where the layout specification is stored
    attr_reader :instances # Instances by label

    def layout(fields)
      @fields = {}
      fields.each do |field, type|
        @fields[field] = type
        attr_reader field
      end

      @instances = {}
    end

    def [](type)
      @instances[type] or raise ArgumentError, "No such #{self.name}: #{type.inspect}"
    end
  end

  attr_reader :label # Label for an instance of a template

  def initialize(label, opts)
    @label = label
    self.class.fields.keys.each do |key|
      unless opts.has_key?(key)
        raise ArgumentError, "#{self.class.name} #{@label.inspect} is missing field: #{key}"
      end
    end

    opts.each do |key, val|
      unless self.class.fields.has_key?(key)
        raise ArgumentError, "Unknown field for #{self.class.name} #{@label.inspect}: #{key}"
      end

      unless val.is_a? self.class.fields[key]
        raise ArgumentError, "Invalid type for #{key.inspect} of #{self.class.name} #{@label.inspect}: Expected #{self.class.fields[key].name}, received #{val.class.name}"
      end

      instance_variable_set("@#{key}", val)
    end

    self.class.instances[@label] = self
  end

end

class Terrain < Template
  layout(
    char: String,
    color: TCOD::Color,
    passable: Boolean
  )
end


Terrain.new(:floor, 
  char: ' ', 
  color: TCOD::Color.rgb(77,60,41), 
  passable: true
)

Terrain.new(:wall, 
  char: ' ', 
  color: TCOD::Color::WHITE, 
  passable: false
)


class Species < Template
  layout(
    char: String,
    color: TCOD::Color,
    fov_range: Integer,
    base_hp: Integer,
  )
end

Species.new(:player, 
  char: '@', 
  color: TCOD::Color::WHITE, 
  fov_range: 8,
  base_hp: 10
)

Species.new(:burrower, 
  char: 'b', 
  color: TCOD::Color::GREY, 
  fov_range: 8,
  base_hp: 10
)

Species.new(:nommer, 
  char: 'n', 
  color: TCOD::Color::RED, 
  fov_range: 8,
  base_hp: 5
)

class Effect
  def initialize(&block)
    @block = block
  end

  def render(con)
    @block.call(con)
  end
end

class Rect
  attr_accessor :x1, :y1, :x2, :y2
  def initialize (x, y, w, h)
    @x1 = x
    @y1 = y
    @x2 = x + w
    @y2 = y + h
  end

  def center
    center_x = (@x1 + @x2) / 2
    center_y = (@y1 + @y2) / 2
    [center_x, center_y]
  end

  def intersect (other)
    return (@x1 <= other.x2 and @x2 >= other.x1 and
      @y1 <= other.y2 and @y2 >= other.y1)
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
          @cellmap[x].push(Cell.new(x, y, Terrain[:wall]))
        end
      end
    end
    map
  end

  def paint_room(room)
    (room.x1 ... room.x2).each do |x|
      (room.y1 ... room.y2).each do |y|
        @map[x][y].terrain = Terrain[:floor]
      end
    end
  end

  def paint_htunnel(x1, x2, y)
    ([x1,x2].min .. [x1,x2].max).each do |x|
      @map[x][y].terrain = Terrain[:floor]
    end
  end

  def paint_vtunnel(y1, y2, x)
    ([y1,y2].min .. [y1,y2].max).each do |y|
      @map[x][y].terrain = Terrain[:floor]
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

  def [](x)
    @cellmap[x]
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

  def init_mind
    @state = STATE_IDLE
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
    case @state
    when STATE_IDLE
      if (target = nearby_enemy)
        order_attack(target)
        return take_turn
      end

      random_walk

    when STATE_FOLLOWING
      if (target = nearby_enemy)
        order_attack(target)
        return take_turn
      end

      unless walk_path
        @path = path_to($player)
        walk_path
      end

    when STATE_MOVING
      if (target = nearby_enemy)
        order_attack(target)
        return take_turn
      end

      unless walk_path
        @state = STATE_FOLLOWING
      end

    when STATE_ATTACKING
      if @cell.distance_to(@target) < 5
        $log.write "#{name} damages #{@target.name} #{@target.hp}/#{@target.max_hp}"
        @target.hp -= 1
        if @target.hp == 0
          @target.cell.contents.delete(@target)
          @target = nil
          @state = STATE_IDLE
        end
      else
        @path = path_to(@target) unless walk_path
      end
    end
  end

  ### Orders

  def order_follow(target)
    @path = nil
    @state = STATE_FOLLOWING
    @following = target
  end

  def order_move(cell)
    @state = STATE_MOVING
    @path = path_to(cell)
  end

  def order_attack(target)
    @path = nil
    @state = STATE_ATTACKING
    @target = target
  end

  def order_burrow(cell)
    @burrowing = true
    @path = path_to(cell, true)
  end
end

class Creature < Thing
  attr_accessor :tamer, :pets, :memory_map
  attr_accessor :fov_map, :fov_range
  attr_accessor :type, :template, :char, :color
  attr_accessor :state
  attr_accessor :hp, :max_hp

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
    @char = @template.char
    @color = @template.color
    @fov_range = @template.fov_range

    @hp = 5
    @max_hp = 5

    init_mind
  end

  def name # placeholder
    @type.to_s
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
    target.terrain = Terrain[:floor]
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

  def dislikes?(obj)
    obj.tamer != @tamer && obj != @tamer
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

  ### Debug
  
  def to_s
    "<Creature :#{@type} (#{x},#{y})>"
  end
end

class Player < Creature
  def initialize
    super(:player)
  end

  def summon_pets
    @cell.adjacent.find_all { |x| x.passable? }.sample.put(@pets[0])
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
    $game.change_map($mapgen.classic(SCREEN_WIDTH, SCREEN_HEIGHT))
    opposite = (@dir == :down ? :up : :down)
    cell = $map.cells.find { |c| c.contents.find { |obj| obj.is_a?(Staircase) && obj.dir == opposite } }
    cell.put($player)
    $player.summon_pets
  end
end


class Game
  attr_accessor :log, :effects

  def initialize
    $player = Player.new
    burrower = Creature.new(:burrower)
    burrower.tamer = $player
    $player.pets.push(burrower)
    burrower.order_follow($player)
    change_map($mapgen.classic(SCREEN_WIDTH, SCREEN_HEIGHT))
    $map.upstair.put($player)
    $player.summon_pets

    $log = MessageLog.new
    $log.messages.push("Hullo there!")

    enemy = Creature.new(:nommer)
    $map.some_passable_cell.put(enemy)

    @effects = []
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
      $map.downstair.put(Creature.new(:nommer))
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
      con.print_rect(0, i, width, height, msg)
    end

    console.blit(con, 0, 0, width, height, x, y)
  end
end


class MainGameUI
  STATE_MAIN = :main
  STATE_LOG = :show_log

  def initialize
    @pet = nil # Selected pet
    @burrowing = false
    @state = STATE_MAIN
  end

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

  def render_main
    con = TCOD::Console.new($map.width, $map.height) # Temporary console
    con.set_background_flag(TCOD::BKGND_SET)

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
          con.put_char_ex(cell.x, cell.y, obj.char, obj.color, terrain.color)
        end
      elsif remembered
        con.put_char_ex(cell.x, cell.y, obj.char, obj.color * 0.5, terrain.color * 0.5)
      else
        con.put_char(cell.x, cell.y, ' ', TCOD::BKGND_NONE)
      end
    end

    if @pet
      if @burrowing
        path = @pet.path_to($map[$mouse.cx][$mouse.cy], true)
        if path
          path.each { |x, y| con.set_char_background(x, y, TCOD::Color::GREY) }
        end
      else
        cell = $map[$mouse.cx][$mouse.cy]
        path = @pet.path_to(cell)
        if path
          if cell.creatures.find { |cre| @pet.dislikes?(cre) }
            color = TCOD::Color::RED
          else
            color = TCOD::Color::GREEN
          end
          path.each { |x, y| con.set_char_background(x, y, color) }
        end
      end
    end

    render_sidebar(con)
    $log.render(con, 0, SCREEN_HEIGHT-3, SCREEN_WIDTH, 3)

    # Hover inspect
    $map[$mouse.cx][$mouse.cy].contents.each do |obj|
      if obj.is_a? Creature
        con.print_ex(SCREEN_WIDTH-1, SCREEN_HEIGHT-2, TCOD::BKGND_DEFAULT, TCOD::RIGHT, obj.name)
      end
    end

    $game.effects.each do |effect|
      effect.render(con)
    end

    Console.blit(con, 0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, 0, 0)
  end

  def render_sidebar(con)
    sidebar = "Mispy\n"
    $player.pets.each_with_index do |pet, i|
      if pet == @pet
        sidebar += "{bg:white}{fg:black}#{i+1}. #{pet.type}{stop}\n"
      else
        sidebar += "#{i+1}. #{pet.type}\n"
      end
      sidebar += pet.state.to_s + "\n"
    end
    con.print_rect(0, 0, SCREEN_HEIGHT, 10, colorify(sidebar))
  end

  def render_log
    $log.render(Console, 0, 0, SCREEN_HEIGHT, SCREEN_WIDTH)
  end

  def render
    case @state
    when STATE_MAIN then render_main
    when STATE_LOG then render_log
    end
  end

  # Handle keypress in state where a pet has been previously
  # assigned to @pet
  def on_pet_keypress(key)
    case key.c
    when 'b' then
      @burrowing = !@burrowing
    when 'f' then
      i = 0
      effect = Effect.new do |con| 
        path = @pet.path_to($map[$mouse.cx][$mouse.cy])
        unless path.nil?
          path.each do |x, y|
            color = (i % 2 == 0 ? TCOD::Color::ORANGE : TCOD::Color::RED)
            con.set_char_background(x, y, color)
            i += 1
          end
        end
      end
      $game.effects.push(effect)
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
    when '1' then
      if @pet
        @pet = nil
      else
        @pet = $player.pets[0]
      end
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
      if @pet
        on_pet_keypress(key)
      else
        on_main_keypress(key)
      end
    when STATE_LOG then on_log_keypress(key)
    end
  end

  def submit_order
    if @burrowing
      @pet.order_burrow($map[$mouse.cx][$mouse.cy])
    else
      cell = $map[$mouse.cx][$mouse.cy]
      if (target = cell.creatures.find { |cre| @pet.dislikes?(cre) })
        @pet.order_attack(target)
      else
        @pet.order_move($map[$mouse.cx][$mouse.cy])
      end
    end
    @pet = nil
  end

  def on_lclick
    if @pet
      submit_order
    else
      $map[$mouse.cx][$mouse.cy].contents.each do |obj|
        if obj.tamer == $player
          @pet = obj
        end
      end
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

#SDL::TTF.init
#TCOD::System.register_sdl_renderer do |renderer|
#  dst = SDL::Screen.get
#  font = SDL::TTF.open('FreeSerif.ttf', 32, 0)
#  surface = font.render_solid_utf8("hullo", 255, 255, 255)
#  SDL::Surface.blit(surface, 0, 0, 0, 0, dst, 0, 0)
#end

$game = Game.new
$ui = MainGameUI.new
$key = TCOD::Key.new
$mouse = TCOD::Mouse.new

until Console.window_closed?
  $ui.render
  Console.flush

  TCOD.sys_check_for_event(TCOD::EVENT_KEY_PRESS | TCOD::EVENT_MOUSE, $key, $mouse)

  if $key.vk != TCOD::KEY_NONE
    #exit! if $key.vk == TCOD::KEY_ESCAPE
    $ui.on_keypress($key)
  elsif $mouse.lbutton_pressed
    $ui.on_lclick
  end
end
