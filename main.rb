#!/usr/bin/env ruby

require 'libtcod'
require 'sdl'
require 'json'

#actual size of the window
SCREEN_WIDTH = 160
SCREEN_HEIGHT = 100
 
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

  def passable?
    @terrain.passable
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

class Map
  attr_reader :width, :height, :cells
  def initialize(w, h)
    @width = w
    @height = h

    @cells = []
    0.upto(w-1) do |x|
      @cells.push([])
      0.upto(h-1) do |y|
        terrain = Terrain[(rand > 0.8 ? :wall : :floor)]
        cell = Cell.new(x, y, terrain)
        @cells[x].push(cell)
      end
    end
  end

  def each_cell(&b)
    @cells.each do |row|
      row.each do |cell|
        yield cell
      end
    end
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
    #return unless $map.cells[x][y].passable?
    @cell.contents.delete(self) if @cell
    @cell = $map.cells[x][y]
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
    $map = Map.new(SCREEN_WIDTH, SCREEN_HEIGHT)
    $player = Player.new
    $player.move(5,5)
    $player.fov_map = TCOD.map_new($map.width, $map.height)
    $player.memory_map = Bitfield.new($map.width, $map.height)
    $map.each_cell do |cell|
      TCOD.map_set_properties($player.fov_map, cell.x, cell.y, cell.passable?, cell.passable?)
    end
  end

  def save(path)
    mapdata = { 
      width: $map.width,
      height: $map.height,
      cells: [],
      player: $player.save
    }
    0.upto($map.width-1) do |x|
      mapdata[:cells].push([])
      0.upto($map.height-1) do |y|
        mapdata[:cells][x].push(
          { terrain: $map.cells[x][y].terrain.label }
        )
      end
    end
    File.write(path, JSON.dump(mapdata))
  end

  def load(path)
    mapdata = JSON.parse(File.read(path), symbolize_names: true)
    $map = Map.new(mapdata[:width], mapdata[:height])
    $map.each_cell do |cell|
      celldata = mapdata[:cells][cell.x][cell.y]
      cell.terrain = Terrain[celldata[:terrain].to_sym]
    end
    $player = Player.load(mapdata[:player])
    $player.fov_map = TCOD.map_new($map.width, $map.height)
    $map.each_cell do |cell|
      TCOD.map_set_properties($player.fov_map, cell.x, cell.y, cell.passable?, cell.passable?)
    end
  end
end

class MainGameUI
  def render(console)
    con = TCOD::Console.new($map.width, $map.height) # Temporary console
    TCOD.map_compute_fov($player.fov_map, $player.cell.x, $player.cell.y, 10, true, 0)

    $map.cells.each do |row|
      row.each do |cell|
        visible = TCOD.map_is_in_fov($player.fov_map, cell.x, cell.y)
        remembered = $player.memory_map[cell.x][cell.y]
        terrain = cell.terrain
        obj = cell.contents[0] || terrain

        if visible
          $player.memory_map[cell.x][cell.y] = true
          con.put_char_ex(cell.x, cell.y, obj.char, obj.color, terrain.color)
        elsif remembered
          con.put_char_ex(cell.x, cell.y, obj.char, obj.color * 0.5, terrain.color * 0.5)
        else
          con.put_char(cell.x, cell.y, ' ', TCOD::BKGND_NONE)
        end
      end
    end

    Console.blit(con, 0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, 0, 0)
  end

  def on_keypress(key)
    if key.c == 's'
      $game.save("save/game.json")
    elsif key.c == 'l'
      $game.load("save/game.json")
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
