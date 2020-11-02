using DrWatson
@quickactivate
using ArgParse
using GenerativeAD
import StatsBase: fit!, predict
using StatsBase
using BSON
# because of vae and 2stage
using DataFrames
using CSV
using ValueHistories
using ConditionalDists
using GenerativeModels
import GenerativeModels: VAE
using Distributions
using DistributionsAD

s = ArgParseSettings()
@add_arg_table! s begin
   "max_seed"
        required = true
        arg_type = Int
        help = "seed"
    "dataset"
        required = true
        arg_type = String
        help = "dataset"
    "tab_name"
        required = true
        arg_type = "string"
        help = "name of tab -> example: vae_LOSS_tabular_best, wae-vamp_AUC_tabular_best"
end
parsed_args = parse_args(ARGS, s)
@unpack dataset, max_seed, tab_name = parsed_args

#######################################################################################
################ THIS PART IS TO BE PROVIDED FOR EACH MODEL SEPARATELY ################

sp = split(tab_name, "_")
enc = sp[1]
criterion = lowercase(sp[2])

modelname = "$(enc)+ocsvm"

function sample_params()
	par_vec = (round.([10^x for x in -4:0.1:2],digits=5),["poly", "rbf", "sigmoid"],[0.01,0.5,0.99])
	argnames = (:gamma,:kernel,:nu)
	return (;zip(argnames, map(x->sample(x, 1)[1], par_vec))...)
end


function fit(data, parameters, aux_info)
	# construct model - constructor should only accept kwargs
	model = GenerativeAD.Models.OCSVM(;parameters...)

	# sumbsample and fit train data
	tr_data = data[1][1]
	M,N = size(tr_data)
	tr_data = tr_data[:, sample(1:N, min(10000, N), replace=false)]
	try
		global info, fit_t, _, _, _ = @timed fit!(model, data[1][1])
	catch e
		# return an empty array if fit fails so nothing is computed
		return (fit_t = NaN,), [] 
	end

	# construct return information - put e.g. the model structure here for generative models
	training_info = (
		fit_t = fit_t,
		model = nothing
		)

	# now return the different scoring functions
	training_info, [(x->predict(model, x), merge(parameters, aux_info))]
end

####################################################################
################ THIS PART IS COMMON FOR ALL MODELS ################
# set a maximum for parameter sampling retries
try_counter = 0
max_tries = 10*max_seed
while try_counter < max_tries
    parameters = sample_params()

    for seed in 1:max_seed
		savepath = datadir("experiments/tabular/$(modelname)/$(dataset)/seed=$(seed)")
        for mi = 1:10 # iteration through encodings
            aux_info = (model_index=mi, criterion=criterion)
            # get data
            data = GenerativeAD.load_data(dataset, seed=seed)
            data, encoding_name = GenerativeAD.Models.load_encoding(tab_name, data, dataset=dataset, seed=seed, model_index=mi)
                
            # edit parameters
            edited_parameters = GenerativeAD.edit_params(data, parameters)
            edited_parameters =  merge(edited_parameters, aux_info)
            
            @info "Trying to fit $modelname on $dataset with parameters $(edited_parameters)..."
            # check if a combination of parameters and seed alread exists
            if GenerativeAD.check_params(savepath, edited_parameters)
                # fit
                training_info, results = fit(data, edited_parameters, aux_info)
                # here define what additional info should be saved together with parameters, scores, labels and predict times
                save_entries = merge(training_info, (modelname = modelname, 
                                                     seed = seed, 
                                                     dataset = dataset, 
                                                     encoding_name=encoding_name, 
                                                     model_index=mi,
                                                     criterion=criterion))

                # now loop over all anomaly score funs
                for result in results
                    GenerativeAD.experiment(result..., data, savepath; save_entries...)
                end
                global try_counter = max_tries + 1
            else
                @info "Model already present, trying new hyperparameters..."
                global try_counter += 1
            end
        end
	end
end
(try_counter == max_tries) ? (@info "Reached $(max_tries) tries, giving up.") : nothing

