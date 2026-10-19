# frozen_string_literal: true

require 'rack/test'
require_relative '../app/controllers/application_controller'

# Curating a record submitted through a user-facing form. Such a form is a
# cut-down version of the real ones (e.g. a member announcing an
# application); the administrators who curate it know what kind of record it
# really is, the submitter may not. So a record still on a user-facing form
# can be opened under any Core form stored under the same dbname, the edit
# page showing what was submitted first; saving re-stamps the record. A
# record on a Core form stays on it. Nothing here knows any form by name: the
# unit tests use made-up forms.
RSpec.describe 'curating a submitted record' do
  describe '#curation_targets (made-up forms)' do
    before do
      cats = { 'simple_form' => 'UserFacing', 'full_a' => 'Core', 'full_b' => 'Core', 'other_db_form' => 'Core' }
      dbs = { 'simple_form' => 'things', 'full_a' => 'things', 'full_b' => 'things', 'other_db_form' => 'elsewhere' }
      allow_any_instance_of(Object).to receive(:form_category_for) { |_o, form| cats[form] }
      allow_any_instance_of(Object).to receive(:storage_dbname_for) { |_o, form| dbs.fetch(form, form) }
      allow_any_instance_of(Object).to receive(:forms_sharing_dbname) do |_o, *args, **kw|
        dbname = (kw.empty? ? args.last : kw)[:dbname]
        dbs.select { |form, db| db == dbname && cats[form] == 'Core' }.keys.sort
      end
      allow_any_instance_of(Object).to receive(:get_databases)
        .and_return([['Full A', 'full_a'], ['Full B', 'full_b'], ['Other', 'other_db_form']])
    end

    it 'offers the Core forms sharing the dbname of a record on a user-facing form' do
      expect(curation_targets('simple_form')).to eq([['Full A', 'full_a'], ['Full B', 'full_b']])
    end

    it 'offers nothing for a record already on a Core form (its form stays fixed)' do
      expect(curation_targets('full_a')).to eq([])
    end

    it 'offers nothing for an unknown or blank form' do
      expect(curation_targets('nonsense')).to eq([])
      expect(curation_targets('')).to eq([])
      expect(curation_targets(nil)).to eq([])
    end
  end

  describe '#values_not_carried (made-up fields)' do
    it 'lists what the record holds that the target form has no field for, and nothing else' do
      source = CBGP::Dataset.new(type: 'userproject')
      source.title = 'An Application'
      copi = source.fields.find { |f| f[:questionclass] == 'project_main_copi_nie' }
      source.public_send("#{copi[:method]}=", ['12345678Z'])
      allow(CBGP::Dataset).to receive(:load_from_primary_id).and_return(source)

      lost = values_not_carried(from_form: 'userproject', to_form: 'personnel_project', primary_id: 'x')

      expect(lost.map(&:first)).to eq(['Main co-PI DNI/NIE/PAS']) # not on the Personnel form; the title is
      expect(lost.first.last).to eq('12345678Z')
    end

    it 'is empty when every entered value has a field on the target form' do
      source = CBGP::Dataset.new(type: 'userproject')
      source.title = 'An Application'
      allow(CBGP::Dataset).to receive(:load_from_primary_id).and_return(source)

      expect(values_not_carried(from_form: 'userproject', to_form: 'european_research_project', primary_id: 'x')).to eq([])
    end
  end

  describe 'with the real ontology' do
    it 'lets a submitted project be curated as each of the five project forms, in the user\'s language' do
      forms = curation_targets('userproject').map(&:last)
      expect(forms).to contain_exactly('european_research_project', 'national_regional_research_project',
                                       'private_research_project', 'personnel_project',
                                       'programa_propio_research_project')
    end

    it 'does not offer a curated project any other form' do
      expect(curation_targets('european_research_project')).to eq([])
      expect(curation_targets('member')).to eq([])
    end

    it 'knows each form\'s category' do
      expect(form_category_for('userproject')).to eq('UserFacing')
      expect(form_category_for('personnel_project')).to eq('Core')
      expect(form_category_for('project')).to be_nil # a dbname, not a form
    end
  end

  describe 'the edit page', type: :request do
    include Rack::Test::Methods

    def app
      CBGP::DatabasesApp
    end

    # like the real loader: a record of the form it is asked to load under
    def entry_for(form)
      ds = CBGP::Dataset.new(type: form)
      ds.primary_id = 'sub-1'
      ds.title = 'An Application'
      ds
    end

    def sign_in(user)
      header 'Host', 'localhost'
      post '/cbgp/login', username: user, password: 'test'
    end

    before do
      allow(CBGP::Dataset).to receive(:load_from_primary_id) { |*args, **kw| entry_for((kw.empty? ? args.last : kw)[:database]) }
      allow(CBGP::RelatedRecords).to receive(:panels_for).and_return([])
      allow_any_instance_of(CBGP::DatabasesApp).to receive(:get_record_form).and_return('userproject')
    end

    context 'as an administrator' do
      before { sign_in('test-admin') }

      it 'shows the submitted record with a link per form it can be curated as' do
        get '/cbgp/dataset/userproject/sub-1'

        expect(last_response.status).to eq(200)
        body = last_response.body
        expect(body).to include('has not been classified yet')
        %w[european_research_project national_regional_research_project private_research_project personnel_project].each do |form|
          expect(body).to include(%(href="/cbgp/dataset/#{form}/sub-1"))
        end
        expect(body).not_to include('Nothing changes until you save')
      end

      it 'opens the record under the chosen Core form instead of redirecting back' do
        get '/cbgp/dataset/european_research_project/sub-1'

        expect(last_response.status).to eq(200)
        expect(last_response.body).to include('/cbgp/validate-dataset/european_research_project') # saving posts under this form
        expect(last_response.body).to include('Nothing changes until you save')
        expect(last_response.body).to include('href="/cbgp/dataset/userproject/sub-1"') # back to the submitted view
        expect(last_response.body).not_to include('has not been classified yet')
      end

      it 'warns about entered values the chosen form has no field for' do
        allow_any_instance_of(CBGP::DatabasesApp).to receive(:values_not_carried)
          .and_return([['Responsible PI DNI/NIE/PAS', '12345678Z']])
        get '/cbgp/dataset/european_research_project/sub-1'

        expect(last_response.body).to include('will not be kept when you save')
        expect(last_response.body).to include('Responsible PI DNI/NIE/PAS')
        expect(last_response.body).to include('12345678Z')
      end

      it 'says nothing about lost values when there are none' do
        allow_any_instance_of(CBGP::DatabasesApp).to receive(:values_not_carried).and_return([])
        get '/cbgp/dataset/european_research_project/sub-1'

        expect(last_response.body).not_to include('will not be kept when you save')
      end

      it 'still sends the shared-dbname URL to the record\'s own form' do
        get '/cbgp/dataset/project/sub-1'

        expect(URI(last_response.headers['Location']).path).to eq('/cbgp/dataset/userproject/sub-1')
      end

      it 'does not let a record already on a Core form be opened under a different one' do
        allow_any_instance_of(CBGP::DatabasesApp).to receive(:get_record_form).and_return('personnel_project')
        get '/cbgp/dataset/european_research_project/sub-1'

        expect(URI(last_response.headers['Location']).path).to eq('/cbgp/dataset/personnel_project/sub-1')
      end

      it 'does not offer curation on the page of a record that is already on a Core form' do
        allow_any_instance_of(CBGP::DatabasesApp).to receive(:get_record_form).and_return('personnel_project')
        get '/cbgp/dataset/personnel_project/sub-1'

        expect(last_response.body).not_to include('has not been classified yet')
      end
    end

    context 'as a non-administrator' do
      before { sign_in('test-user') }

      it 'is sent back to the record\'s own form rather than curating it' do
        get '/cbgp/dataset/european_research_project/sub-1'

        expect(URI(last_response.headers['Location'].to_s).path).to eq('/cbgp/dataset/userproject/sub-1')
      end

      it 'is not shown the classification panel' do
        get '/cbgp/dataset/userproject/sub-1'

        expect(last_response.body).not_to include('has not been classified yet')
      end
    end
  end
end
