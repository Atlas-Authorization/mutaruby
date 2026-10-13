# frozen_string_literal: true

require_relative '../lib/calc'

RSpec.describe Calc do
  it('adds') { expect(Calc.add(2, 3)).to eq(5) }

  describe '.positive?' do
    it('is true above zero') { expect(Calc.positive?(1)).to be(true) }
    it('is false at zero') { expect(Calc.positive?(0)).to be(false) }
  end

  it 'clamps below zero' do
    expect(Calc.clamp_low(-4)).to eq(0)
    expect(Calc.clamp_low(-1)).to eq(0)
    expect(Calc.clamp_low(0)).to eq(0)
    expect(Calc.clamp_low(0.5)).to eq(0.5)
    expect(Calc.clamp_low(7)).to eq(7)
  end

  it 'counts' do
    expect(Calc.count_to(3)).to eq(3)
    expect(Calc.count_to(0)).to eq(0)
    expect(Calc.count_to(-2)).to eq(0)
  end

  it('shouts') { expect(Calc.shout('hi')).to eq('HI') }
end
