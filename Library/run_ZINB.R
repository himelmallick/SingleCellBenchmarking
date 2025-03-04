##########################################
# Zero-inflated Negative Binomial (ZINB) #
##########################################

###########################
# Load Essential Packages #
###########################

# pacman, devtools, dplyr, tidyverse, fdrtool, ashr, GMPR, swfdr, genefilter, IHW
load_essential_packages()

###########################################
# Load Dedicated Method-specific Packages #
###########################################

pacman::p_load("pbapply", "pscl", "glmmTMB")

#########################
# Fit ZINB To A Dataset #
#########################

fit.ZINB <- function(features, 
                     metadata, 
                     libSize, 
                     ID, 
                     transformation,
                     multiple_qvalues){
  
  #########################
  # Transformation if any #
  #########################
  
  if (transformation!='NONE') stop ('Transformation currently not supported for a default ZINB model. Use NONE.')
  
  #####################
  # Per-feature model #
  #####################
  
  paras <- pbapply::pbsapply(1:ncol(features), simplify=FALSE, function(x){
    
    ###############################
    # Extract features one by one #
    ###############################
    
    featuresVector <- features[, x]
    
    #################################
    # Create per-feature input data #
    #################################
    
    dat_sub <- data.frame(expr = as.numeric(featuresVector), metadata, libSize, ID)
    formula<-as.formula(paste("expr ~ ", paste(colnames(metadata), collapse= "+")))
    
    ##############################################
    # Automatic library size adjustment for GLMs #
    ##############################################
    
    if(length(unique(libSize)) > 1){ # To prevent offsetting with TSS-normalized data 
      formula<-update(formula, . ~ . - offset(log(libSize)))
    }
    
    #######################
    # Random effect model #
    #######################
    
    if(!length(ID) == length(unique(ID))){ 
      formula<-update(formula, . ~ . + (1|ID))
      fit <- tryCatch({
        fit1 <- glmmTMB::glmmTMB(formula = formula,  
                                 data = dat_sub, 
                                 family = nbinom2, 
                                 ziformula = ~1)
      }, error=function(err){
        fit1 <- try({glmmTMB::glmmTMB(formula = formula,  
                                      data = dat_sub, 
                                      family = nbinom2, 
                                      ziformula = ~1)}) 
        return(fit1)
      })
      
      ###################################
      # Summarize Coefficient Estimates #
      ###################################
      
      if (class(fit) != "try-error"){
        para<-as.data.frame(coef(summary(fit))$cond)[-1,-3]
      } else{
        print(paste("Fitting problem for feature", x, "returning NA"))
        para<- as.data.frame(matrix(NA, nrow=ncol(metadata), ncol=3))
      }
      colnames(para)<-c('coef', 'stderr', 'pval')
      para$metadata<-colnames(metadata)
      para$feature<-colnames(features)[x]
    }
    
    #######################
    # Fixed effects model #
    #######################
    
    else{ 
      fit <- tryCatch({
        fit1 <- pscl::zeroinfl(formula, 
                               data = dat_sub, 
                               dist = "negbin")

      }, error=function(err){
        fit1 <- try({pscl::zeroinfl(formula, 
                                    data = dat_sub, 
                                    dist = "negbin")}) 
        return(fit1)
      })
      
      ###################################
      # Summarize Coefficient Estimates #
      ###################################
      
      if (class(fit) != "try-error"){
        para<-as.data.frame(summary(fit)$coefficients$count)[-c(1, (ncol(metadata)+2)),-3]
        } else{
          print(paste("Fitting problem for feature", x, "returning NA"))
          para<- as.data.frame(matrix(NA, nrow=ncol(metadata), ncol=3))  
      }
      colnames(para)<-c('coef', 'stderr', 'pval')
      para$metadata<-colnames(metadata)
      para$feature<-colnames(features)[x]
    }
    return(para)
  })
  
  ###################
  # Combine results #
  ###################
  
  paras<-do.call(rbind, paras)
  
  ###############################################
  # Calculate multiple qvalues only if prompted #
  ###############################################
  
  if(multiple_qvalues){
    paras<-append_qvalues(features, metadata, paras)
  } else{
    paras$qval_BH<-as.numeric(p.adjust(paras$pval, method = 'BH'))
  }
  
  #################
  # Return output #
  #################
  
  paras<-paras[order(paras$qval_BH, decreasing=FALSE),]
  paras<-dplyr::select(paras, c('feature', 'metadata'), everything())
  rownames(paras)<-NULL
  return(paras)    
}

##################################
# Fit ZINB To A List of Datasets #
##################################

list.ZINB<-function(physeq, transformation = 'NONE', multiple_qvalues = TRUE){
  foreach(physeq = physeq, 
          .export = c("pvalueAdjustment_HM", "append_qvalues",
                      "fit.ZINB"), 
          .packages = c("tidyverse", "fdrtool", "ashr", "GMPR", "swfdr", "genefilter", "IHW",
                        "pbapply", "pscl", "glmmTMB"),
          .errorhandling = "remove") %dopar% 
    {
      start.time<-Sys.time()
      features<-physeq$features
      metadata<-physeq$metadata
      libSize<-physeq$libSize
      ID<-physeq$ID
      DD<-fit.ZINB(features, metadata, libSize, ID, transformation, multiple_qvalues)
      DD$pairwiseAssociation<-paste('pairwiseAssociation', 1:nrow(DD), sep='')
      wh.TP<-intersect(grep("[[:print:]]+\\_TP$", DD$metadata), grep("[[:print:]]+\\_TP$", DD$feature))
      newname<-paste0(DD$pairwiseAssociation[wh.TP], "_TP")
      DD$pairwiseAssociation[wh.TP]<-newname
      DD<-dplyr::select(DD, c('pairwiseAssociation', 'feature', 'metadata'), everything())
      stop.time<-Sys.time()
      time<-as.numeric(round(difftime(stop.time, start.time, units="min"),3), units = "mins")
      DD$time<-time
      return(DD)
    }
}

