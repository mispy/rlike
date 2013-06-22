require 'ostruct'

include TCOD

class ConfigBuilder
  attr_accessor :obj

  def method_missing(meth, *args, &block)
    if block
      val = ConfigBuilder.build(&block)
    elsif args.length > 1
      val = args
    else
      val = args[0]
    end

    if val.is_a? Hash
      val = OpenStruct.new(val)
    end

    if @obj.is_a?(OpenStruct) || @obj.respond_to?(meth.to_s+'=')
      @obj.send(meth.to_s+'=', val)
    else
      @obj.instance_variable_set('@'+meth.to_s, val)
    end
  end

  def self.build(klass=OpenStruct, *args, &b)
    builder = self.new(klass.new(*args))
    builder.instance_eval(&b)
    builder.obj
  end

  def initialize(obj)
    @obj = obj
  end
end

def terrain(label, &block)
  Terrain[label] = ConfigBuilder.build(Terrain, &block)
end

def species(label, &block)
  Species[label] = ConfigBuilder.build(Species, &block)
end

def ability(label, &block)
  Ability[label] = ConfigBuilder.build(Ability, &block)
end

terrain :floor do
  name "Floor"
  char '.'
  color Color::WHITE
  bg_color Color::BLACK
  passable true
end

terrain :grass do
  name "Grass"
  char '.'
  color Color::DARK_GREEN
  bg_color Color::BLACK
  passable true
end

terrain :wall do
  name "Wall"
  char '#'
  color Color::WHITE
  bg_color Color::BLACK
  passable false
end

terrain :rock do
  name "Rock"
  char ' '
  color Color::BLACK
  bg_color Color::BLACK
  passable false
end

species :player do
  name "Player"
  char '@'
  color Color::WHITE
  fov_range 20
  base_hp 10
end

species :pyromouse do
  name "Pyromouse"
  char 'r'
  color Color::RED
  fov_range 8
  base_hp 10
end

species :cryobeetle do
  name "Cryobeetle"
  char 'b'
  color Color::LIGHTEST_BLUE
  fov_range 8
  base_hp 10
end

species :gridbug do
  name "Gridbug"
  char 'x'
  color Color::PURPLE
  fov_range 8
  base_hp 5
end

ability :firewave do
  name "Fire Wave"
  key 'w'
  targets :wave
  colors Color::ORANGE, Color::RED
  effect type: :damage, amount: 5
end

ability :fireball do
  name "Fireball"
  key 'b'
  targets :projectile
  colors Color::ORANGE, Color::RED
  projectile do
    char '*'
    impact_radius 5
    impact_effect type: :damage, amount: 5
  end
end
