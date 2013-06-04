#!/usr/bin/env ruby

require 'libtcod'
require 'sdl'
require 'json'
require 'pry'

#actual size of the window
SCREEN_WIDTH = 80
SCREEN_HEIGHT = 50
 
LIMIT_FPS = 20  #20 frames-per-second maximum

Console = TCOD::Console.root

module TCOD
  class Color
    def save
      [self[:r], self[:g], self[:b]]
    end

    def self.load(data)
      Color.rgb(*data)
    end
  end
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

  def save
    @arr.to_a
  end

  def self.load(data)
    field = Bitfield.new(data.length, data[0].length)
    field.instance_eval {
      @arr = data
    }
    field
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

  def passable?
    @terrain.passable
  end

  def put(obj)
    obj.move(@x,@y)
  end
end

class TerrainType
  attr_reader :label, :char, :color, :passable
  def initialize(label, char, color, passable)
    @label = label
    @char = char
    @color = color
    @passable = passable
  end
end

Terrain = {
  floor: TerrainType.new(:floor, ' ', TCOD::Color.rgb(77,60,41), true),
  wall: TerrainType.new(:wall, ' ', TCOD::Color::WHITE, false)
}

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
  attr_reader :width, :height, :cells
  def initialize(w, h)
    @width = w
    @height = h
    @cellmap = []
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
end

class Player
  attr_reader :char, :cell, :color
  attr_accessor :fov_map, :memory_map

  def initialize
    @char = '@'
    @color = TCOD::Color::WHITE
    @fov_map = nil # TCOD field of view map
    @memory_map = nil # Exploration state map
  end

  def move(x, y)
    return unless $map[x][y].passable?
    @cell.contents.delete(self) if @cell
    @cell = $map[x][y]
    @cell.contents.push(self)
  end

  def save
    {
      x: @cell.x,
      y: @cell.y,
      char: @char,
      color: @color.save,
      memory_map: @memory_map.save
    }
  end

  def self.load(data)
    player = Player.new
    player.instance_eval {
      @char = data[:char]
      @color = TCOD::Color.load(data[:color])
      @memory_map = Bitfield.load(data[:memory_map])
      move(data[:x], data[:y])
    }
    player
  end
end

class Game
  def initialize
    $player = Player.new
    change_map($mapgen.classic(SCREEN_WIDTH, SCREEN_HEIGHT))
    $map.upstair.put($player)
  end
  
  def change_map(new_map)
    $map = new_map

    $player.fov_map = TCOD.map_new($map.width, $map.height)
    $map.cells.each do |cell|
      TCOD.map_set_properties($player.fov_map, cell.x, cell.y, cell.passable?, cell.passable?)
    end

    $player.memory_map = Bitfield.new($map.width, $map.height)
  end
end


class Obj
  attr_accessor :char, :color
end

class Staircase < Obj
  attr_reader :dir

  def initialize(dir)
    @dir = dir
    @char = @dir == :up ? '<' : '>'
    @color = TCOD::Color::WHITE
  end

  def activate
    $game.change_map($mapgen.classic(SCREEN_WIDTH, SCREEN_HEIGHT))
    opposite = (@dir == :down ? :up : :down)
    cell = $map.cells.find { |c| c.contents.find { |obj| obj.is_a?(Staircase) && obj.dir == opposite } }
    $player.move(cell.x,cell.y)
  end
end

class MainGameUI
  def render(console)
    con = TCOD::Console.new($map.width, $map.height) # Temporary console
    TCOD.map_compute_fov($player.fov_map, $player.cell.x, $player.cell.y, 10, true, 0)

    $map.cells.each do |cell|
      visible = TCOD.map_is_in_fov($player.fov_map, cell.x, cell.y)
      remembered = $player.memory_map[cell.x][cell.y]
      terrain = cell.terrain
      obj = cell.contents[-1] || terrain

      if visible
        $player.memory_map[cell.x][cell.y] = true
        con.put_char_ex(cell.x, cell.y, obj.char, obj.color, terrain.color)
      elsif remembered
        con.put_char_ex(cell.x, cell.y, obj.char, obj.color * 0.5, terrain.color * 0.5)
      else
        con.put_char(cell.x, cell.y, ' ', TCOD::BKGND_NONE)
      end
    end

    Console.blit(con, 0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, 0, 0)
  end

  def on_keypress(key)
    case key.c
    when 's' then $game.save("save/game.json")
    when 'l' then $game.load("save/game.json")
    when '`' then binding.pry
    when '>'
      $player.cell.contents.each do |obj|
        obj.activate if obj.is_a?(Staircase) && obj.dir == :down
      end
    when '<'
      $player.cell.contents.each do |obj|
        obj.activate if obj.is_a?(Staircase) && obj.dir == :up
      end
    end

    if Console.key_pressed?(TCOD::KEY_UP)
      $player.move($player.cell.x, $player.cell.y-1)
    elsif Console.key_pressed?(TCOD::KEY_DOWN)
      $player.move($player.cell.x, $player.cell.y+1)
    elsif Console.key_pressed?(TCOD::KEY_LEFT)
      $player.move($player.cell.x-1, $player.cell.y)
    elsif Console.key_pressed?(TCOD::KEY_RIGHT)
      $player.move($player.cell.x+1, $player.cell.y)
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
until Console.window_closed?
  $ui.render(Console)
  Console.flush

  key = Console.check_for_keypress
  if key.vk != TCOD::KEY_NONE
    exit! if key.vk == TCOD::KEY_ESCAPE
    $ui.on_keypress(key)
  end
end
