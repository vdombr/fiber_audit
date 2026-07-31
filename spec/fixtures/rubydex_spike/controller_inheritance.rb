# frozen_string_literal: true

class ApplicationController
end

class UsersController < ApplicationController
  def index
    render json: { users: [] }
  end
end
