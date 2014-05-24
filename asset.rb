#!/usr/bin/env ruby

# A simple asset pipeline

def save(obj, path)
  File.open(path+'.msh', 'w') do |f|
    f.write Marshal.dump(obj)
  end
end

def read(path)
  Marshal.load File.read(path+'.msh')
end

def asset(name)
  Asset[name]
end

def key(str)
  ints = str.scan(/\d+/)
  if ints.length
    ints[0].to_i
  else
    str
  end
end

module Asset
  TILEMAP_WIDTH = 32

  class << self
    attr_reader :index
  end

  def self.compile_all

    files = Dir.glob('image/*').sort do |a,b|
      key(a) <=> key(b)
    end

    `montage -mode concatenate -background none -tile #{TILEMAP_WIDTH} #{files.join(' ')} build/tileset.png`

    index = {}
    files.each_with_index do |fn, i|
      index[File.basename(fn)] = i
    end
    save index, 'build/asset_index'
  end

  def self.setup
    @index = read 'build/asset_index'
  end

  def self.[](name)
    setup if @index.nil?
    @index[name]
  end
end
