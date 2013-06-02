#!/usr/bin/env ruby

require 'libtcod'

#actual size of the window
SCREEN_WIDTH = 80
SCREEN_HEIGHT = 50
 
LIMIT_FPS = 20  #20 frames-per-second maximum

Console = TCOD::Console.root
 
def handle_keys
  key = Console.wait_for_keypress(true)

  if key.vk == TCOD::KEY_ENTER && key.lalt
    #Alt+Enter: toggle fullscreen
    Console.set_fullscreen(!Console.is_fullscreen?)
  elsif key.vk == TCOD::KEY_ESCAPE
    return true  #exit game
  end

  #movement keys
  if Console.key_pressed?(TCOD::KEY_UP)
      $playery -= 1
  elsif Console.key_pressed?(TCOD::KEY_DOWN)
      $playery += 1
  elsif Console.key_pressed?(TCOD::KEY_LEFT)
      $playerx -= 1
  elsif Console.key_pressed?(TCOD::KEY_RIGHT)
      $playerx += 1
  end

  false
end
 
#############################################
# Initialization & Main Loop
#############################################
 
Console.set_custom_font('arial12x12.png', TCOD::FONT_TYPE_GREYSCALE | TCOD::FONT_LAYOUT_TCOD, 0, 0)
Console.init_root(SCREEN_WIDTH, SCREEN_HEIGHT, 'ruby/TCOD tutorial', false, TCOD::RENDERER_SDL)
TCOD.sys_set_fps(LIMIT_FPS)
 
$playerx = SCREEN_WIDTH/2
$playery = SCREEN_HEIGHT/2

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

menu = Menu.new
until Console.window_closed?
  menu.print(Console)
  Console.flush

  key = Console.check_for_keypress
  if key.vk != TCOD::KEY_NONE
    exit! if key.vk == TCOD::KEY_ESCAPE
    menu.on_keypress(key)
  end
end
